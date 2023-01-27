// Copyright Materialize, Inc. and contributors. All rights reserved.
//
// Use of this software is governed by the Business Source License
// included in the LICENSE file.
//
// As of the Change Date specified in that file, in accordance with
// the Business Source License, use of this software will be governed
// by the Apache License, Version 2.0.

//! Logging dataflows for events generated by timely dataflow.

use std::any::Any;
use std::collections::BTreeMap;
use std::rc::Rc;
use std::time::Duration;

use differential_dataflow::collection::AsCollection;
use differential_dataflow::operators::arrange::arrangement::Arrange;
use mz_expr::{permutation_for_arrangement, MirScalarExpr};
use timely::communication::Allocate;
use timely::dataflow::channels::pact::Exchange;
use timely::dataflow::operators::capture::EventLink;
use timely::dataflow::operators::Filter;
use timely::logging::{ParkEvent, TimelyEvent, WorkerIdentifier};

use mz_compute_client::logging::LoggingConfig;
use mz_ore::cast::CastFrom;
use mz_repr::{datum_list_size, datum_size, Datum, DatumVec, Diff, Row, Timestamp};
use mz_timely_util::activator::RcActivator;
use mz_timely_util::buffer::ConsolidateBuffer;
use mz_timely_util::replay::MzReplay;

use crate::compute_state::ComputeState;
use crate::logging::persist::persist_sink;
use crate::logging::{LogVariant, TimelyLog};
use crate::typedefs::{KeysValsHandle, RowSpine};

/// Constructs the logging dataflow for timely logs.
///
/// Params
/// * `worker`: The Timely worker hosting the log analysis dataflow.
/// * `config`: Logging configuration
/// * `linked`: The source to read log events from.
/// * `activator`: A handle to acknowledge activations.
///
/// Returns a map from log variant to a tuple of a trace handle and a permutation to reconstruct
/// the original rows.
pub fn construct<A: Allocate>(
    worker: &mut timely::worker::Worker<A>,
    config: &LoggingConfig,
    compute_state: &mut ComputeState,
    linked: std::rc::Rc<EventLink<Timestamp, (Duration, WorkerIdentifier, TimelyEvent)>>,
    activator: RcActivator,
) -> BTreeMap<LogVariant, (KeysValsHandle, Rc<dyn Any>)> {
    let interval_ms = std::cmp::max(1, config.interval.as_millis());
    let peers = worker.peers();

    // A dataflow for multiple log-derived arrangements.
    let traces = worker.dataflow_named("Dataflow: timely logging", move |scope| {
        let (mut logs, token) =
            Some(linked).mz_replay(scope, "timely logs", config.interval, activator);

        // If logging is disabled, we still need to install the indexes, but we can leave them
        // empty. We do so by immediately filtering all logs events.
        // TODO(teskje): Remove this once we remove the arranged introspection sources.
        if !config.enable_logging {
            logs = logs.filter(|_| false);
        }

        use timely::dataflow::operators::generic::builder_rc::OperatorBuilder;

        let mut demux = OperatorBuilder::new("Timely Logging Demux".to_string(), scope.clone());

        use timely::dataflow::channels::pact::Pipeline;
        let mut input = demux.new_input(&logs, Pipeline);

        let (mut operates_out, operates) = demux.new_output();
        let (mut channels_out, channels) = demux.new_output();
        let (mut addresses_out, addresses) = demux.new_output();
        let (mut parks_out, parks) = demux.new_output();
        let (mut messages_sent_out, messages_sent) = demux.new_output();
        let (mut messages_received_out, messages_received) = demux.new_output();
        let (mut schedules_duration_out, schedules_duration) = demux.new_output();
        let (mut schedules_histogram_out, schedules_histogram) = demux.new_output();

        let mut demux_buffer = Vec::new();
        demux.build(move |_capability| {
            // These two maps track operator and channel information
            // so that they can be deleted when we observe the drop
            // events for the corresponding operators.
            let mut operates_data = BTreeMap::new();
            let mut channels_data = BTreeMap::new();
            let mut parks_data = BTreeMap::new();
            let mut schedules_stash = BTreeMap::new();
            let mut messages_sent_data: BTreeMap<_, Vec<Diff>> = BTreeMap::new();
            let mut messages_received_data: BTreeMap<_, Vec<Diff>> = BTreeMap::new();
            let mut schedules_data: BTreeMap<_, Vec<(isize, Diff)>> = BTreeMap::new();
            move |_frontiers| {
                let mut operates = operates_out.activate();
                let mut channels = channels_out.activate();
                let mut addresses = addresses_out.activate();
                let mut parks = parks_out.activate();
                let mut messages_sent = messages_sent_out.activate();
                let mut messages_received = messages_received_out.activate();
                let mut schedules_duration = schedules_duration_out.activate();
                let mut schedules_histogram = schedules_histogram_out.activate();

                let mut operates_session = ConsolidateBuffer::new(&mut operates, 0);
                let mut channels_session = ConsolidateBuffer::new(&mut channels, 1);
                let mut addresses_session = ConsolidateBuffer::new(&mut addresses, 2);
                let mut parks_session = ConsolidateBuffer::new(&mut parks, 3);
                let mut messages_sent_session = ConsolidateBuffer::new(&mut messages_sent, 4);
                let mut messages_received_session =
                    ConsolidateBuffer::new(&mut messages_received, 5);
                let mut schedules_duration_session =
                    ConsolidateBuffer::new(&mut schedules_duration, 6);
                let mut schedules_histogram_session =
                    ConsolidateBuffer::new(&mut schedules_histogram, 7);

                input.for_each(|cap, data| {
                    data.swap(&mut demux_buffer);

                    for (time, worker, datum) in demux_buffer.drain(..) {
                        let time_ns = time.as_nanos();
                        let time_ms = (((time.as_millis() / interval_ms) + 1) * interval_ms)
                            .try_into()
                            .expect("must fit");

                        match datum {
                            TimelyEvent::Operates(event) => {
                                // Record operator information so that we can replay a negated
                                // version when the operator is dropped.
                                operates_data.insert((event.id, worker), event.clone());

                                operates_session
                                    .give(&cap, (((event.id, worker), event.name), time_ms, 1));

                                let address_row = (event.id, worker, event.addr);
                                addresses_session.give(&cap, (address_row, time_ms, 1));
                            }
                            TimelyEvent::Channels(event) => {
                                // Record channel information so that we can replay a negated
                                // version when the host dataflow is dropped.
                                channels_data
                                    .entry((event.scope_addr[0], worker))
                                    .or_insert_with(Vec::new)
                                    .push(event.clone());

                                // Present channel description.
                                let d = (
                                    (event.id, worker),
                                    event.source.0,
                                    event.source.1,
                                    event.target.0,
                                    event.target.1,
                                );
                                channels_session.give(&cap, (d, time_ms, 1));

                                let address_row = (event.id, worker, event.scope_addr);
                                addresses_session.give(&cap, (address_row, time_ms, 1));
                            }
                            TimelyEvent::Shutdown(event) => {
                                // Dropped operators should result in a negative record for
                                // the `operates` collection, cancelling out the initial
                                // operator announcement.
                                if let Some(event) = operates_data.remove(&(event.id, worker)) {
                                    operates_session.give(
                                        &cap,
                                        (((event.id, worker), event.name), time_ms, -1),
                                    );

                                    // Retract schedules information for the operator
                                    if let Some(schedules) =
                                        schedules_data.remove(&(event.id, worker))
                                    {
                                        for (index, (pow, elapsed_ns)) in schedules
                                            .into_iter()
                                            .enumerate()
                                            .filter(|(_, (pow, _))| *pow != 0)
                                        {
                                            schedules_duration_session.give(
                                                &cap,
                                                ((event.id, worker), time_ms, -elapsed_ns),
                                            );
                                            schedules_histogram_session.give(
                                                &cap,
                                                (
                                                    (event.id, worker, 1 << index),
                                                    time_ms,
                                                    Diff::cast_from(-pow),
                                                ),
                                            );
                                        }
                                    }

                                    // If we are observing a dataflow shutdown, we should also
                                    // issue a deletion for channels in the dataflow.
                                    if event.addr.len() == 1 {
                                        let dataflow_id = event.addr[0];
                                        if let Some(events) =
                                            channels_data.remove(&(dataflow_id, worker))
                                        {
                                            for event in events {
                                                // Retract channel description.
                                                let d = (
                                                    (event.id, worker),
                                                    event.source.0,
                                                    event.source.1,
                                                    event.target.0,
                                                    event.target.1,
                                                );
                                                channels_session.give(&cap, (d, time_ms, -1));

                                                if let Some(sent) =
                                                    messages_sent_data.remove(&(event.id, worker))
                                                {
                                                    for (index, count) in sent.iter().enumerate() {
                                                        let data = (
                                                            ((event.id, worker), index),
                                                            time_ms,
                                                            -count,
                                                        );
                                                        messages_sent_session.give(&cap, data);
                                                    }
                                                }
                                                if let Some(received) = messages_received_data
                                                    .remove(&(event.id, worker))
                                                {
                                                    for (index, count) in
                                                        received.iter().enumerate()
                                                    {
                                                        let data = (
                                                            ((event.id, worker), index),
                                                            time_ms,
                                                            -count,
                                                        );
                                                        messages_received_session.give(&cap, data);
                                                    }
                                                }

                                                let address_row =
                                                    (event.id, worker, event.scope_addr);
                                                addresses_session
                                                    .give(&cap, (address_row, time_ms, -1));
                                            }
                                        }
                                    }

                                    let address_row = (event.id, worker, event.addr);
                                    addresses_session.give(&cap, (address_row, time_ms, -1));
                                }
                            }
                            TimelyEvent::Park(event) => match event {
                                ParkEvent::Park(duration) => {
                                    parks_data.insert(worker, (time_ns, duration));
                                }
                                ParkEvent::Unpark => {
                                    let (start_ns, requested) =
                                        parks_data.remove(&worker).expect("park data must exist");
                                    let duration_ns = time_ns - start_ns;
                                    let requested =
                                        requested.map(|r| r.as_nanos().next_power_of_two());
                                    let pow = duration_ns.next_power_of_two();
                                    parks_session
                                        .give(&cap, ((worker, pow, requested), time_ms, 1));
                                }
                            },

                            TimelyEvent::Messages(event) => {
                                let length = Diff::try_from(event.length).unwrap();
                                if event.is_send {
                                    // Record messages sent per channel and source
                                    // We can send data to at most `peers` targets.
                                    messages_sent_data
                                        .entry((event.channel, event.source))
                                        .or_insert_with(|| vec![0; peers])[event.target] += length;
                                    let d = ((event.channel, event.source), event.target);
                                    messages_sent_session.give(&cap, (d, time_ms, length));
                                } else {
                                    // Record messages received per channel and target
                                    // We can receive data from at most `peers` targets.
                                    messages_received_data
                                        .entry((event.channel, event.target))
                                        .or_insert_with(|| vec![0; peers])[event.source] += length;
                                    let d = ((event.channel, event.target), event.source);
                                    messages_received_session.give(&cap, (d, time_ms, length));
                                }
                            }
                            TimelyEvent::Schedule(event) => {
                                // Pair of operator ID and worker
                                let key = (event.id, worker);
                                match event.start_stop {
                                    timely::logging::StartStop::Start => {
                                        debug_assert!(!schedules_stash.contains_key(&key));
                                        schedules_stash.insert(key, time_ns);
                                    }
                                    timely::logging::StartStop::Stop => {
                                        debug_assert!(schedules_stash.contains_key(&key));
                                        let start = schedules_stash
                                            .remove(&key)
                                            .expect("start event absent");
                                        let elapsed_ns = time_ns - start;

                                        // Record count and elapsed for retraction
                                        // Note that we store the histogram for retraction with
                                        // 64 buckets, which should be enough to cover all scheduling
                                        // durations up to ~500 years. One bucket is an `(isize, isize`)
                                        // pair, which should consume 1KiB on 64-bit arch per entry.
                                        let (count, duration) = &mut schedules_data
                                            .entry(key)
                                            .or_insert_with(|| vec![(0, 0); 64])[usize::cast_from(
                                            elapsed_ns.next_power_of_two().trailing_zeros(),
                                        )];
                                        *count += 1;
                                        let elapsed_ns_diff = Diff::try_from(elapsed_ns).unwrap();
                                        *duration += elapsed_ns_diff;

                                        schedules_duration_session
                                            .give(&cap, (key, time_ms, elapsed_ns_diff));
                                        let d = (event.id, worker, elapsed_ns.next_power_of_two());
                                        schedules_histogram_session.give(&cap, (d, time_ms, 1));
                                    }
                                }
                            }
                            _ => {}
                        }
                    }
                });
            }
        });

        // Accumulate the durations of each operator.
        let elapsed = schedules_duration
            .as_collection()
            .arrange_core::<_, RowSpine<_, _, _, _>>(
                Exchange::new(|(((_, w), ()), _, _)| u64::cast_from(*w)),
                "PreArrange Timely duration",
            )
            .as_collection(|(op, worker), _| {
                Row::pack_slice(&[
                    Datum::UInt64(u64::cast_from(*op)),
                    Datum::UInt64(u64::cast_from(*worker)),
                ])
            });

        // Accumulate histograms of execution times for each operator.
        let histogram = schedules_histogram
            .as_collection()
            .arrange_core::<_, RowSpine<_, _, _, _>>(
                Exchange::new(|(((_, w, _), ()), _, _)| u64::cast_from(*w)),
                "PreArrange Timely histogram",
            )
            .as_collection(|(op, worker, pow), _| {
                let row = Row::pack_slice(&[
                    Datum::UInt64(u64::cast_from(*op)),
                    Datum::UInt64(u64::cast_from(*worker)),
                    Datum::UInt64(u64::try_from(*pow).expect("pow too big")),
                ]);
                row
            });

        let operates = operates
            .as_collection()
            .arrange_core::<_, RowSpine<_, _, _, _>>(
                Exchange::new(|((((_, w), _), ()), _, _)| u64::cast_from(*w)),
                "PreArrange Timely operates",
            )
            .as_collection(move |((id, worker), name), _| {
                Row::pack_slice(&[
                    Datum::UInt64(u64::cast_from(*id)),
                    Datum::UInt64(u64::cast_from(*worker)),
                    Datum::String(name),
                ])
            });

        let addresses = addresses
            .as_collection()
            .arrange_core::<_, RowSpine<_, _, _, _>>(
                Exchange::new(|(((_, w, _), ()), _, _)| u64::cast_from(*w)),
                "PreArrange Timely addresses",
            )
            .as_collection(|(event_id, worker, addr), _| {
                create_address_row(*event_id, *worker, addr)
            });

        let parks = parks
            .as_collection()
            .arrange_core::<_, RowSpine<_, _, _, _>>(
                Exchange::new(|(((w, _, _), ()), _, _)| u64::cast_from(*w)),
                "PreArrange Timely parks",
            )
            .as_collection(|(worker, duration_ns, requested), ()| {
                Row::pack_slice(&[
                    Datum::UInt64(u64::cast_from(*worker)),
                    Datum::UInt64(u64::try_from(*duration_ns).expect("pow too big")),
                    requested
                        .map(|requested| {
                            Datum::UInt64(requested.try_into().expect("requested too big"))
                        })
                        .unwrap_or(Datum::Null),
                ])
            });

        let messages_received = messages_received
            .as_collection()
            .arrange_core::<_, RowSpine<_, _, _, _>>(
                Exchange::new(|((((_, w), _), ()), _, _)| u64::cast_from(*w)),
                "PreArrange Timely messages received",
            )
            .as_collection(move |((channel, target), source), ()| {
                Row::pack_slice(&[
                    Datum::UInt64(u64::cast_from(*channel)),
                    Datum::UInt64(u64::cast_from(*source)),
                    Datum::UInt64(u64::cast_from(*target)),
                ])
            });

        let messages_sent = messages_sent
            .as_collection()
            .arrange_core::<_, RowSpine<_, _, _, _>>(
                Exchange::new(|((((_, w), _), ()), _, _)| u64::cast_from(*w)),
                "PreArrange Timely messages sent",
            )
            .as_collection(move |((channel, source), target), ()| {
                Row::pack_slice(&[
                    Datum::UInt64(u64::cast_from(*channel)),
                    Datum::UInt64(u64::cast_from(*source)),
                    Datum::UInt64(u64::cast_from(*target)),
                ])
            });

        let channels = channels
            .as_collection()
            .arrange_core::<_, RowSpine<_, _, _, _>>(
                Exchange::new(|((((_, w), _, _, _, _), ()), _, _)| u64::cast_from(*w)),
                "PreArrange Timely operates",
            )
            .as_collection(
                move |((id, worker), source_node, source_port, target_node, target_port), ()| {
                    Row::pack_slice(&[
                        Datum::UInt64(u64::cast_from(*id)),
                        Datum::UInt64(u64::cast_from(*worker)),
                        Datum::UInt64(u64::cast_from(*source_node)),
                        Datum::UInt64(u64::cast_from(*source_port)),
                        Datum::UInt64(u64::cast_from(*target_node)),
                        Datum::UInt64(u64::cast_from(*target_port)),
                    ])
                },
            );

        // Restrict results by those logs that are meant to be active.
        let logs = vec![
            (LogVariant::Timely(TimelyLog::Operates), operates),
            (LogVariant::Timely(TimelyLog::Channels), channels),
            (LogVariant::Timely(TimelyLog::Elapsed), elapsed),
            (LogVariant::Timely(TimelyLog::Histogram), histogram),
            (LogVariant::Timely(TimelyLog::Addresses), addresses),
            (LogVariant::Timely(TimelyLog::Parks), parks),
            (LogVariant::Timely(TimelyLog::MessagesSent), messages_sent),
            (
                LogVariant::Timely(TimelyLog::MessagesReceived),
                messages_received,
            ),
        ];

        let mut result = BTreeMap::new();
        for (variant, collection) in logs {
            if config.index_logs.contains_key(&variant) {
                let key = variant.index_by();
                let (_, value) = permutation_for_arrangement(
                    &key.iter()
                        .cloned()
                        .map(MirScalarExpr::Column)
                        .collect::<Vec<_>>(),
                    variant.desc().arity(),
                );
                let rows = collection.map({
                    let mut row_buf = Row::default();
                    let mut datums = DatumVec::new();
                    move |row| {
                        let datums = datums.borrow_with(&row);
                        row_buf.packer().extend(key.iter().map(|k| datums[*k]));
                        let row_key = row_buf.clone();
                        row_buf.packer().extend(value.iter().map(|k| datums[*k]));
                        let row_val = row_buf.clone();
                        (row_key, row_val)
                    }
                });

                let trace = rows
                    .arrange_named::<RowSpine<_, _, _, _>>(&format!("ArrangeByKey {:?}", variant))
                    .trace;
                result.insert(variant.clone(), (trace, Rc::clone(&token)));
            }

            if let Some((id, meta)) = config.sink_logs.get(&variant) {
                tracing::debug!("Persisting {:?} to {:?}", &variant, meta);
                persist_sink(*id, meta, compute_state, collection);
            }
        }
        result
    });

    traces
}

fn create_address_row(id: usize, worker: WorkerIdentifier, address: &[usize]) -> Row {
    let id_datum = Datum::UInt64(u64::cast_from(id));
    let worker_datum = Datum::UInt64(u64::cast_from(worker));
    // we're collecting into a Vec because we need to iterate over the Datums
    // twice: once for determining the size of the row, then again for pushing
    // them
    let address_datums: Vec<_> = address
        .iter()
        .map(|i| Datum::UInt64(u64::cast_from(*i)))
        .collect();

    let row_capacity =
        datum_size(&id_datum) + datum_size(&worker_datum) + datum_list_size(&address_datums);

    let mut address_row = Row::with_capacity(row_capacity);
    let mut packer = address_row.packer();
    packer.push(id_datum);
    packer.push(worker_datum);
    packer.push_list(address_datums);

    address_row
}
