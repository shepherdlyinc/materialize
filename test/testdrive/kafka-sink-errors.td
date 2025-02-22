# Copyright Materialize, Inc. and contributors. All rights reserved.
#
# Use of this software is governed by the Business Source License
# included in the LICENSE file at the root of this repository.
#
# As of the Change Date specified in that file, in accordance with
# the Business Source License, use of this software will be governed
# by the Apache License, Version 2.0.

#
# Test various errors that can happen at CREATE SINK time and check how they are reported to the user
#

> CREATE MATERIALIZED VIEW v1 (f1) AS VALUES (1);

> CREATE CONNECTION kafka_conn
  TO KAFKA (BROKER '${testdrive.kafka-addr}', SECURITY PROTOCOL PLAINTEXT);

> CREATE CONNECTION IF NOT EXISTS csr_conn TO CONFLUENT SCHEMA REGISTRY (
    URL '${testdrive.schema-registry-url}'
  );

! CREATE SINK invalid_key
  IN CLUSTER ${arg.single-replica-cluster}
  FROM v1
  INTO KAFKA CONNECTION kafka_conn (TOPIC 'testdrive-kafka-sink-errors-${testdrive.seed}')
  KEY(f2)
  FORMAT AVRO USING CONFLUENT SCHEMA REGISTRY CONNECTION csr_conn
  ENVELOPE DEBEZIUM
contains:No such column: f2

! CREATE SINK invalid_legacy_ids
  IN CLUSTER ${arg.single-replica-cluster}
  FROM v1
  INTO KAFKA CONNECTION kafka_conn (TOPIC 'testdrive-kafka-sink-errors-${testdrive.seed}', LEGACY IDS)
  FORMAT AVRO USING CONFLUENT SCHEMA REGISTRY CONNECTION csr_conn
  ENVELOPE DEBEZIUM
contains:LEGACY IDs option is not supported

#
# Sink dependencies
#

> CREATE SINK s1
  IN CLUSTER ${arg.single-replica-cluster}
  FROM v1
  INTO KAFKA CONNECTION kafka_conn (TOPIC 'testdrive-kafka-sink-errors-${testdrive.seed}')
  FORMAT AVRO USING CONFLUENT SCHEMA REGISTRY CONNECTION csr_conn
  ENVELOPE DEBEZIUM

! CREATE SINK s2
  IN CLUSTER ${arg.single-replica-cluster}
  FROM s1
  INTO KAFKA CONNECTION kafka_conn (TOPIC 'testdrive-kafka-sink-errors-${testdrive.seed}')
  FORMAT AVRO USING CONFLUENT SCHEMA REGISTRY CONNECTION csr_conn
  ENVELOPE DEBEZIUM
contains:catalog item 'materialize.public.s1' is a sink and so cannot be depended upon

! CREATE VIEW v2 AS SELECT * FROM s1
contains:catalog item 'materialize.public.s1' is a sink and so cannot be depended upon

! SELECT * FROM s1
contains:catalog item 'materialize.public.s1' is a sink and so cannot be depended upon

> DROP SINK s1

$ file-append path=invalid-keytab
nonsense

#
# FORMAT
#

! CREATE SINK invalid_format
  IN CLUSTER ${arg.single-replica-cluster}
  FROM v1
  INTO KAFKA CONNECTION kafka_conn (TOPIC 'testdrive-kafka-sink-errors-${testdrive.seed}')
  ENVELOPE DEBEZIUM
contains:sink without format not yet supported

! CREATE SINK invalid_format
  IN CLUSTER ${arg.single-replica-cluster}
  FROM v1
  INTO KAFKA CONNECTION kafka_conn (TOPIC 'testdrive-kafka-sink-errors-${testdrive.seed}')
  FORMAT NO_SUCH_FORMAT
  ENVELOPE DEBEZIUM
contains:found identifier "no_such_format"

! CREATE SINK invalid_envelope
  IN CLUSTER ${arg.single-replica-cluster}
  FROM v1
  INTO KAFKA CONNECTION kafka_conn (TOPIC 'testdrive-kafka-sink-errors-${testdrive.seed}')
  FORMAT JSON
contains:ENVELOPE clause is required

# Expect empty output
> SHOW SINKS
