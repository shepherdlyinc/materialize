// Copyright Materialize, Inc. and contributors. All rights reserved.
//
// Use of this software is governed by the Business Source License
// included in the LICENSE file.
//
// As of the Change Date specified in that file, in accordance with
// the Business Source License, use of this software will be governed
// by the Apache License, Version 2.0.

//! This module provides functions that
//! build decoding pipelines from raw source streams.
//!
//! The primary exports are [`render_decode_delimited`], and
//! [`render_decode_cdcv2`]. See their docs for more details about their differences.

use std::cell::RefCell;
use std::collections::VecDeque;
use std::rc::Rc;
use std::time::Duration;

use differential_dataflow::capture::YieldingIter;
use differential_dataflow::{AsCollection, Collection, Hashable};
use mz_avro::{AvroDeserializer, GeneralDeserializer};
use mz_interchange::avro::ConfluentAvroResolver;
use mz_ore::error::ErrorExt;
use mz_repr::{Datum, Diff, Row, Timestamp};
use mz_storage_types::configuration::StorageConfiguration;
use mz_storage_types::connections::CsrConnection;
use mz_storage_types::errors::{CsrConnectError, DecodeError, DecodeErrorKind};
use mz_storage_types::sources::encoding::{
    AvroEncoding, DataEncoding, DataEncodingInner, RegexEncoding,
};
use mz_timely_util::builder_async::{
    Event as AsyncEvent, OperatorBuilder as AsyncOperatorBuilder, PressOnDropButton,
};
use regex::Regex;
use timely::dataflow::channels::pact::Exchange;
use timely::dataflow::operators::Map;
use timely::dataflow::{Scope, Stream};
use timely::scheduling::SyncActivator;
use tracing::error;

use crate::decode::avro::AvroDecoderState;
use crate::decode::csv::CsvDecoderState;
use crate::decode::protobuf::ProtobufDecoderState;
use crate::healthcheck::{HealthStatusMessage, HealthStatusUpdate, StatusNamespace};
use crate::metrics::decode::DecodeMetricDefs;
use crate::source::types::{DecodeResult, SourceOutput};

mod avro;
mod csv;
mod protobuf;

/// Decode delimited CDCv2 messages.
///
/// This not only literally decodes the avro-encoded messages, but
/// also builds a differential dataflow collection that respects the
/// data and progress messages in the underlying CDCv2 stream.
pub fn render_decode_cdcv2<G: Scope<Timestamp = Timestamp>>(
    input: &Collection<G, SourceOutput<Option<Vec<u8>>, Option<Vec<u8>>>, Diff>,
    schema: String,
    storage_configuration: StorageConfiguration,
    csr_connection: Option<CsrConnection>,
    confluent_wire_format: bool,
) -> (Collection<G, Row, Diff>, PressOnDropButton) {
    let channel_rx = Rc::new(RefCell::new(VecDeque::new()));
    let activator_set: Rc<RefCell<Option<SyncActivator>>> = Rc::new(RefCell::new(None));

    let mut builder = AsyncOperatorBuilder::new("CDCv2-Decode".to_owned(), input.scope());

    let mut input_handle = builder.new_disconnected_input(
        &input.inner,
        Exchange::new(|(x, _, _): &(SourceOutput<Option<Vec<u8>>, _>, _, _)| x.key.hashed()),
    );

    let channel_tx = Rc::clone(&channel_rx);
    let activator_get = Rc::clone(&activator_set);
    builder.build(move |_| async move {
        let registry = match csr_connection {
            None => None,
            Some(conn) => Some(
                // This also panics on connections errors. cdc_v2 is unused so we don't handle
                // errors right now.
                conn.connect(&storage_configuration)
                    .await
                    .expect("CSR connection unexpectedly missing secrets"),
            ),
        };

        // We have already checked validity of the schema by now, so this can't fail.
        let mut resolver =
            ConfluentAvroResolver::new(&schema, registry, confluent_wire_format).unwrap();

        while let Some(event) = input_handle.next().await {
            let AsyncEvent::Data(_time, data) = event else {
                continue;
            };

            for (data, _time, _diff) in data {
                let value = match &data.value {
                    Some(value) => value,
                    None => continue,
                };
                let (mut data, schema, _) = match resolver.resolve(&*value).await {
                    Ok(Ok(ok)) => ok,
                    // TODO: restart the dataflow on transient errors
                    Ok(Err(e)) | Err(e) => {
                        error!("Failed to get schema info for CDCv2 record: {}", e);
                        continue;
                    }
                };
                let d = GeneralDeserializer {
                    schema: schema.top_node(),
                };
                let dec = mz_interchange::avro::cdc_v2::Decoder;
                let message = match d.deserialize(&mut data, dec) {
                    Ok(ok) => ok,
                    Err(e) => {
                        error!("Failed to deserialize avro message: {}", e);
                        continue;
                    }
                };
                channel_tx.borrow_mut().push_back(message);
            }
            if let Some(activator) = activator_get.borrow_mut().as_mut() {
                activator.activate().unwrap()
            }
        }
    });
    struct VdIterator<T>(Rc<RefCell<VecDeque<T>>>);
    impl<T> Iterator for VdIterator<T> {
        type Item = T;
        fn next(&mut self) -> Option<T> {
            self.0.borrow_mut().pop_front()
        }
    }
    // this operator returns a thread-safe drop-token
    let (token, stream) = differential_dataflow::capture::source::build(input.scope(), move |ac| {
        *activator_set.borrow_mut() = Some(ac);
        YieldingIter::new_from(VdIterator(channel_rx), Duration::from_millis(10))
    });

    // The token returned by DD's operator is not compatible with the shutdown mechanism used in
    // storage so we create a dummy operator to hold onto that token.
    let builder = AsyncOperatorBuilder::new("CDCv2-Token".to_owned(), input.scope());
    let button = builder.build(move |_caps| async move {
        let _dd_token = token;
        // Keep this operator around until shutdown
        std::future::pending::<()>().await;
    });
    (stream.as_collection(), button.press_on_drop())
}

// These don't know how to find delimiters --
// they just go from sequences of vectors of bytes (for which we already know the delimiters)
// to rows, and can eventually just be planned as `HirRelationExpr::Map`. (TODO)
#[derive(Debug)]
pub(crate) enum PreDelimitedFormat {
    Bytes,
    Text,
    Json,
    Regex(Regex, Row),
    Protobuf(ProtobufDecoderState),
}

impl PreDelimitedFormat {
    pub fn decode(&mut self, bytes: &[u8]) -> Result<Option<Row>, DecodeErrorKind> {
        match self {
            PreDelimitedFormat::Bytes => Ok(Some(Row::pack(Some(Datum::Bytes(bytes))))),
            PreDelimitedFormat::Json => {
                let j = mz_repr::adt::jsonb::Jsonb::from_slice(bytes).map_err(|e| {
                    DecodeErrorKind::Bytes(format!(
                        "Failed to decode JSON: {}",
                        // See if we can output the string that failed to be converted to JSON.
                        match std::str::from_utf8(bytes) {
                            Ok(str) => str.to_string(),
                            // Otherwise produce the nominally helpful error.
                            Err(_) => e.display_with_causes().to_string(),
                        }
                    ))
                })?;
                Ok(Some(j.into_row()))
            }
            PreDelimitedFormat::Text => {
                let s = std::str::from_utf8(bytes)
                    .map_err(|_| DecodeErrorKind::Text("Failed to decode UTF-8".to_string()))?;
                Ok(Some(Row::pack(Some(Datum::String(s)))))
            }
            PreDelimitedFormat::Regex(regex, row_buf) => {
                let s = std::str::from_utf8(bytes)
                    .map_err(|_| DecodeErrorKind::Text("Failed to decode UTF-8".to_string()))?;
                let captures = match regex.captures(s) {
                    Some(captures) => captures,
                    None => return Ok(None),
                };
                row_buf.packer().extend(
                    captures
                        .iter()
                        .skip(1)
                        .map(|c| Datum::from(c.map(|c| c.as_str()))),
                );
                Ok(Some(row_buf.clone()))
            }
            PreDelimitedFormat::Protobuf(pb) => pb.get_value(bytes).transpose(),
        }
    }
}

#[derive(Debug)]
pub(crate) enum DataDecoderInner {
    Avro(AvroDecoderState),
    DelimitedBytes {
        delimiter: u8,
        format: PreDelimitedFormat,
    },
    Csv(CsvDecoderState),

    PreDelimited(PreDelimitedFormat),
}

#[derive(Debug)]
struct DataDecoder {
    inner: DataDecoderInner,
    metrics: DecodeMetricDefs,
}

impl DataDecoder {
    pub async fn next(
        &mut self,
        bytes: &mut &[u8],
    ) -> Result<Result<Option<Row>, DecodeErrorKind>, CsrConnectError> {
        let result = match &mut self.inner {
            DataDecoderInner::DelimitedBytes { delimiter, format } => {
                match bytes.iter().position(|&byte| byte == *delimiter) {
                    Some(chunk_idx) => {
                        let data = &bytes[0..chunk_idx];
                        *bytes = &bytes[chunk_idx + 1..];
                        format.decode(data)
                    }
                    None => Ok(None),
                }
            }
            DataDecoderInner::Avro(avro) => avro.decode(bytes).await?,
            DataDecoderInner::Csv(csv) => csv.decode(bytes),
            DataDecoderInner::PreDelimited(format) => {
                let result = format.decode(*bytes);
                *bytes = &[];
                result
            }
        };
        Ok(result)
    }

    /// Get the next record if it exists, assuming an EOF has occurred.
    ///
    /// This is distinct from `next` because, for example, a CSV record should be returned even if it
    /// does not end in a newline.
    pub fn eof(
        &mut self,
        bytes: &mut &[u8],
    ) -> Result<Result<Option<Row>, DecodeErrorKind>, CsrConnectError> {
        let result = match &mut self.inner {
            DataDecoderInner::Csv(csv) => {
                let result = csv.decode(bytes);
                csv.reset_for_new_object();
                result
            }
            DataDecoderInner::DelimitedBytes { format, .. } => {
                let data = std::mem::take(bytes);
                // If we hit EOF with no bytes left in the buffer it means the file had a trailing
                // \n character that can be ignored. Otherwise, we decode the final bytes as normal
                if data.is_empty() {
                    Ok(None)
                } else {
                    format.decode(data)
                }
            }
            _ => Ok(None),
        };
        Ok(result)
    }

    pub fn log_errors(&self, n: usize) {
        self.metrics.count_errors(&self.inner, n);
    }

    pub fn log_successes(&self, n: usize) {
        self.metrics.count_successes(&self.inner, n);
    }
}

async fn get_decoder(
    encoding: DataEncoding,
    debug_name: &str,
    // Information about optional transformations that can be eagerly done.
    // If the decoding elects to perform them, it should replace this with
    // `None`.
    is_connection_delimited: bool,
    metrics: DecodeMetricDefs,
    storage_configuration: &StorageConfiguration,
) -> Result<DataDecoder, CsrConnectError> {
    let decoder = match encoding.inner {
        DataEncodingInner::Avro(AvroEncoding {
            schema,
            csr_connection,
            confluent_wire_format,
        }) => {
            let csr_client = match csr_connection {
                None => None,
                Some(csr_connection) => Some(csr_connection.connect(storage_configuration).await?),
            };
            let state = avro::AvroDecoderState::new(
                &schema,
                csr_client,
                debug_name.to_string(),
                confluent_wire_format,
            )
            .expect("Failed to create avro decoder, even though we validated ccsr client creation in purification.");
            DataDecoder {
                inner: DataDecoderInner::Avro(state),
                metrics,
            }
        }
        DataEncodingInner::Text
        | DataEncodingInner::Bytes
        | DataEncodingInner::Json
        | DataEncodingInner::Protobuf(_)
        | DataEncodingInner::Regex(_) => {
            let after_delimiting = match encoding.inner {
                DataEncodingInner::Regex(RegexEncoding { regex }) => {
                    PreDelimitedFormat::Regex(regex.regex, Default::default())
                }
                DataEncodingInner::Protobuf(encoding) => {
                    PreDelimitedFormat::Protobuf(ProtobufDecoderState::new(encoding).expect(
                        "Failed to create protobuf decoder, even though we validated ccsr \
                                    client creation in purification.",
                    ))
                }
                DataEncodingInner::Bytes => PreDelimitedFormat::Bytes,
                DataEncodingInner::Json => PreDelimitedFormat::Json,
                DataEncodingInner::Text => PreDelimitedFormat::Text,
                _ => unreachable!(),
            };
            let inner = if is_connection_delimited {
                DataDecoderInner::PreDelimited(after_delimiting)
            } else {
                DataDecoderInner::DelimitedBytes {
                    delimiter: b'\n',
                    format: after_delimiting,
                }
            };
            DataDecoder { inner, metrics }
        }
        DataEncodingInner::Csv(enc) => {
            let state = CsvDecoderState::new(enc);
            DataDecoder {
                inner: DataDecoderInner::Csv(state),
                metrics,
            }
        }
        DataEncodingInner::RowCodec(_) => {
            unreachable!("RowCodec sources should not go through the general decoding path.")
        }
    };
    Ok(decoder)
}

async fn decode_delimited(
    decoder: &mut DataDecoder,
    buf: &[u8],
) -> Result<Result<Option<Row>, DecodeError>, CsrConnectError> {
    let mut remaining_buf = buf;
    let value = decoder.next(&mut remaining_buf).await?;

    let result = match value {
        Ok(value) => {
            if remaining_buf.is_empty() {
                match value {
                    Some(value) => Ok(Some(value)),
                    None => decoder.eof(&mut remaining_buf)?,
                }
            } else {
                Err(DecodeErrorKind::Text(format!(
                    "Unexpected bytes remaining for decoded value: {remaining_buf:?}"
                )))
            }
        }
        Err(err) => Err(err),
    };

    Ok(result.map_err(|inner| DecodeError {
        kind: inner,
        raw: buf.to_vec(),
    }))
}

/// Decode already delimited records of data.
///
/// Precondition: each record in the stream has at most one key and at most one value.
/// This function is useful mainly for decoding data from systems like Kafka,
/// that have already separated the stream into records/messages/etc. before we
/// decode them.
///
/// Because we expect the upstream connection to have already delimited the data,
/// we return an error here if the decoder does not consume all the bytes. This
/// often lets us, for example, detect when Avro decoding has gone off the rails
/// (which is not always possible otherwise, since often gibberish strings can be interpreted as Avro,
///  so the only signal is how many bytes you managed to decode).
pub fn render_decode_delimited<G>(
    input: &Collection<G, SourceOutput<Option<Vec<u8>>, Option<Vec<u8>>>, Diff>,
    key_encoding: Option<DataEncoding>,
    value_encoding: DataEncoding,
    debug_name: String,
    metrics: DecodeMetricDefs,
    storage_configuration: StorageConfiguration,
) -> (
    Collection<G, DecodeResult, Diff>,
    Stream<G, HealthStatusMessage>,
)
where
    G: Scope,
{
    let op_name = format!(
        "{}{}DecodeDelimited",
        key_encoding
            .as_ref()
            .map(|key_encoding| key_encoding.op_name())
            .unwrap_or(""),
        value_encoding.op_name()
    );
    let dist =
        |(x, _, _): &(SourceOutput<Option<Vec<u8>>, Option<Vec<u8>>>, _, _)| x.value.hashed();

    let mut builder = AsyncOperatorBuilder::new(op_name, input.scope());

    let (mut output_handle, output) = builder.new_output();
    let mut input = builder.new_input_for(&input.inner, Exchange::new(dist), &output_handle);

    let (_, transient_errors) = builder.build_fallible(move |caps| {
        Box::pin(async move {
            let [cap_set]: &mut [_; 1] = caps.try_into().unwrap();

            let mut key_decoder = match key_encoding {
                Some(encoding) => Some(
                    get_decoder(
                        encoding,
                        &debug_name,
                        true,
                        metrics.clone(),
                        &storage_configuration,
                    )
                    .await?,
                ),
                None => None,
            };

            let mut value_decoder = get_decoder(
                value_encoding,
                &debug_name,
                true,
                metrics,
                &storage_configuration,
            )
            .await?;

            let mut output_container = Vec::new();

            while let Some(event) = input.next().await {
                match event {
                    AsyncEvent::Data(cap, data) => {
                        let mut n_errors = 0;
                        let mut n_successes = 0;
                        for (output, ts, diff) in data.iter() {
                            let SourceOutput {
                                key,
                                value,
                                metadata,
                                position_for_upsert: position,
                            } = output;

                            let key = match key_decoder.as_mut().zip(key.as_ref()) {
                                Some((decoder, buf)) => {
                                    decode_delimited(decoder, buf).await?.transpose()
                                }
                                None => None,
                            };

                            let value = match value.as_ref() {
                                Some(buf) => {
                                    decode_delimited(&mut value_decoder, buf).await?.transpose()
                                }
                                None => None,
                            };

                            if matches!(&key, Some(Err(_))) || matches!(&value, Some(Err(_))) {
                                n_errors += 1;
                            } else if matches!(&value, Some(Ok(_))) {
                                n_successes += 1;
                            }

                            let result = DecodeResult {
                                key,
                                value,
                                position_for_upsert: *position,
                                metadata: metadata.clone(),
                            };
                            output_container.push((result, ts.clone(), *diff));
                        }

                        // Matching historical practice, we only log metrics on the value decoder.
                        if n_errors > 0 {
                            value_decoder.log_errors(n_errors);
                        }
                        if n_successes > 0 {
                            value_decoder.log_successes(n_successes);
                        }

                        output_handle
                            .give_container(&cap, &mut output_container)
                            .await;
                    }
                    AsyncEvent::Progress(frontier) => cap_set.downgrade(frontier.iter()),
                }
            }

            Ok(())
        })
    });

    let health = transient_errors.map(|err: Rc<CsrConnectError>| {
        let halt_status = HealthStatusUpdate::halting(err.display_with_causes().to_string(), None);
        HealthStatusMessage {
            index: 0,
            namespace: if matches!(&*err, CsrConnectError::Ssh(_)) {
                StatusNamespace::Ssh
            } else {
                StatusNamespace::Decode
            },
            update: halt_status,
        }
    });

    (output.as_collection(), health)
}
