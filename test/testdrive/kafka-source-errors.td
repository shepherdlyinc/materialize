# Copyright Materialize, Inc. and contributors. All rights reserved.
#
# Use of this software is governed by the Business Source License
# included in the LICENSE file at the root of this repository.
#
# As of the Change Date specified in that file, in accordance with
# the Business Source License, use of this software will be governed
# by the Apache License, Version 2.0.

# Test that Kafka sources with no format are disallowed.

$ postgres-execute connection=postgres://mz_system:materialize@${testdrive.materialize-internal-sql-addr}
ALTER SYSTEM SET enable_create_source_denylist_with_options = true

> CREATE CONNECTION kafka_conn TO KAFKA (BROKER '${testdrive.kafka-addr}', SECURITY PROTOCOL PLAINTEXT);

! CREATE SOURCE s
  IN CLUSTER ${arg.single-replica-cluster}
  FROM KAFKA CONNECTION kafka_conn (TOPIC 'testdrive-data-${testdrive.seed}')
contains:Source format must be specified

! CREATE CONNECTION no_topic TO KAFKA (BROKER '');
contains:Meta data fetch error: BrokerTransportFailure (Local: Broker transport failure)

# Verify that incorrect/unreachable brokers throw up an error on source creation.

! CREATE CONNECTION fawlty_kafka_conn
  TO KAFKA (BROKER 'non-existent-broker:9092');
contains:Failed to resolve hostname

> CREATE CONNECTION IF NOT EXISTS csr_conn TO CONFLUENT SCHEMA REGISTRY (
    URL '${testdrive.schema-registry-url}'
  );

! CREATE CONNECTION IF NOT EXISTS fawlty_csr_conn TO CONFLUENT SCHEMA REGISTRY (
    URL 'http://non-existent-csr:8081'
  );
contains:failed to lookup address information

# Check that for all tables clause is rejected
! CREATE SOURCE bad_definition1
  IN CLUSTER ${arg.single-replica-cluster}
  FROM KAFKA CONNECTION kafka_conn (TOPIC 'any_topic')
  FORMAT BYTES FOR ALL TABLES;
contains: FOR ALL TABLES is only valid for multi-output sources

# Check that for tables() clause is rejected
! CREATE SOURCE bad_definition2
  IN CLUSTER ${arg.single-replica-cluster}
  FROM KAFKA CONNECTION kafka_conn (TOPIC 'any_topic')
  FORMAT BYTES FOR TABLES (t1);
contains: FOR TABLES (t1) is only valid for multi-output sources

# Ensure the `TOPIC METADATA REFRESH INTERVAL` rejects too large and too
# small values.
! CREATE SOURCE bad_topic_metadata_refresh_interval
  IN CLUSTER ${arg.single-replica-cluster}
  FROM KAFKA CONNECTION kafka_conn (
    TOPIC 'testdrive-thetopic-${testdrive.seed}',
    TOPIC METADATA REFRESH INTERVAL '-30s'
  )
  FORMAT TEXT
  ENVELOPE NONE
contains:cannot convert negative interval to duration

! CREATE SOURCE bad_topic_metadata_refresh_interval
  IN CLUSTER ${arg.single-replica-cluster}
  FROM KAFKA CONNECTION kafka_conn (
    TOPIC 'testdrive-thetopic-${testdrive.seed}',
    TOPIC METADATA REFRESH INTERVAL '1hr 1ms'
  )
  FORMAT TEXT
  ENVELOPE NONE
contains:TOPIC METADATA REFRESH INTERVAL cannot be greater than 1 hour
