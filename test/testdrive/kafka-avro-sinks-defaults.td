# Copyright Materialize, Inc. and contributors. All rights reserved.
#
# Use of this software is governed by the Business Source License
# included in the LICENSE file at the root of this repository.
#
# As of the Change Date specified in that file, in accordance with
# the Business Source License, use of this software will be governed
# by the Apache License, Version 2.0.

# Test Avro UPSERT sinks with null defaults

# sinking directly from an UPSERT source with multi-part key
$ set upsert-keyschema={
    "type": "record",
    "name": "Key",
    "fields": [
        {"name": "key1", "type": "string"},
        {"name": "key2", "type": ["null", "long"]}
    ]
  }

$ set upsert-schema={
        "type" : "record",
        "name" : "test",
        "fields" : [
            {"name":"f1", "type":["null", "string"]},
            {"name":"f2", "type":["long", "null"]},
            {"name":"f3", "type":["long", "string"]}
        ]
    }

$ kafka-create-topic topic=upsert-avro

$ kafka-ingest format=avro topic=upsert-avro key-format=avro key-schema=${upsert-keyschema} schema=${upsert-schema}
{"key1": "fish", "key2": {"long": 2}} {"f1": {"string": "fish"}, "f2": {"long": 1000}, "f3": {"long": 1}}
{"key1": "fisch", "key2": {"long": 42}} {"f1": null, "f2": {"long": 1000}, "f3": {"string": "hello"}}

> CREATE CONNECTION kafka_conn
  TO KAFKA (BROKER '${testdrive.kafka-addr}', SECURITY PROTOCOL PLAINTEXT);

> CREATE CONNECTION IF NOT EXISTS csr_conn TO CONFLUENT SCHEMA REGISTRY (
    URL '${testdrive.schema-registry-url}'
  );

> CREATE SOURCE upsert_input
  IN CLUSTER ${arg.single-replica-cluster}
  FROM KAFKA CONNECTION kafka_conn (TOPIC 'testdrive-upsert-avro-${testdrive.seed}')
  FORMAT AVRO USING CONFLUENT SCHEMA REGISTRY CONNECTION csr_conn
  ENVELOPE UPSERT

# we split avro unions into separate columns
> SELECT * FROM upsert_input;
fisch  42  <null>   1000  <null>  hello
fish    2  fish     1000  1       <null>

# Checking all combination of NULL DEFAULTS with and without values

> CREATE SINK upsert_input_sink1
  IN CLUSTER ${arg.single-replica-cluster}
  FROM upsert_input
  INTO KAFKA CONNECTION kafka_conn (TOPIC 'testdrive-upsert-input-sink1-${testdrive.seed}')
  KEY (key1, key2)
  FORMAT AVRO USING CONFLUENT SCHEMA REGISTRY CONNECTION csr_conn
  (
    NULL DEFAULTS = TRUE
  )
  ENVELOPE UPSERT

$ schema-registry-verify schema-type=avro subject=testdrive-upsert-input-sink1-${testdrive.seed}-value
{"type":"record","name":"envelope","fields":[{"name":"key1","type":"string"},{"name":"key2","type":["null","long"],"default":null},{"name":"f1","type":["null","string"],"default":null},{"name":"f2","type":["null","long"],"default":null},{"name":"f31","type":["null","long"],"default":null},{"name":"f32","type":["null","string"],"default":null}]}

> CREATE SINK upsert_input_sink2
  IN CLUSTER ${arg.single-replica-cluster}
  FROM upsert_input
  INTO KAFKA CONNECTION kafka_conn (TOPIC 'testdrive-upsert-input-sink2-${testdrive.seed}')
  KEY (key1, key2)
  FORMAT AVRO USING CONFLUENT SCHEMA REGISTRY CONNECTION csr_conn
  (
    NULL DEFAULTS
  )
  ENVELOPE UPSERT

$ schema-registry-verify schema-type=avro subject=testdrive-upsert-input-sink2-${testdrive.seed}-value
{"type":"record","name":"envelope","fields":[{"name":"key1","type":"string"},{"name":"key2","type":["null","long"],"default":null},{"name":"f1","type":["null","string"],"default":null},{"name":"f2","type":["null","long"],"default":null},{"name":"f31","type":["null","long"],"default":null},{"name":"f32","type":["null","string"],"default":null}]}

> CREATE SINK upsert_input_sink3
  IN CLUSTER ${arg.single-replica-cluster}
  FROM upsert_input
  INTO KAFKA CONNECTION kafka_conn (TOPIC 'testdrive-upsert-input-sink3-${testdrive.seed}')
  KEY (key1, key2)
  FORMAT AVRO USING CONFLUENT SCHEMA REGISTRY CONNECTION csr_conn
  (
    NULL DEFAULTS = FALSE
  )
  ENVELOPE UPSERT

$ schema-registry-verify schema-type=avro subject=testdrive-upsert-input-sink3-${testdrive.seed}-value
{"type":"record","name":"envelope","fields":[{"name":"key1","type":"string"},{"name":"key2","type":["null","long"]},{"name":"f1","type":["null","string"]},{"name":"f2","type":["null","long"]},{"name":"f31","type":["null","long"]},{"name":"f32","type":["null","string"]}]}

> CREATE SINK upsert_input_sink4
  IN CLUSTER ${arg.single-replica-cluster}
  FROM upsert_input
  INTO KAFKA CONNECTION kafka_conn (TOPIC 'testdrive-upsert-input-sink4-${testdrive.seed}')
  KEY (key1, key2)
  FORMAT AVRO USING CONFLUENT SCHEMA REGISTRY CONNECTION csr_conn
  ENVELOPE UPSERT

$ schema-registry-verify schema-type=avro subject=testdrive-upsert-input-sink4-${testdrive.seed}-value
{"type":"record","name":"envelope","fields":[{"name":"key1","type":"string"},{"name":"key2","type":["null","long"]},{"name":"f1","type":["null","string"]},{"name":"f2","type":["null","long"]},{"name":"f31","type":["null","long"]},{"name":"f32","type":["null","string"]}]}

# Different types of columns
> CREATE TYPE point AS (x integer, y integer);
> CREATE TYPE custom_map AS MAP (KEY TYPE = text, VALUE TYPE = bool)
> CREATE TABLE t (c1 point, c2 text NOT NULL, c3 custom_map, c4 point list);
> INSERT INTO t SELECT ROW(1, 1)::point AS c1, 'text' AS c2, '{a=>true}'::custom_map as c3, LIST[ROW(1, 1)::point] as c4;

> CREATE MATERIALIZED VIEW v AS SELECT * from t;

> CREATE SINK sink1
  IN CLUSTER ${arg.single-replica-cluster}
  FROM v
  INTO KAFKA CONNECTION kafka_conn (TOPIC 'testdrive-sink1-${testdrive.seed}')
  KEY (c2) NOT ENFORCED
  FORMAT AVRO USING CONFLUENT SCHEMA REGISTRY CONNECTION csr_conn
  (
    NULL DEFAULTS
  )
  ENVELOPE UPSERT

$ schema-registry-verify schema-type=avro subject=testdrive-sink1-${testdrive.seed}-value
{"type":"record","name":"envelope","fields":[{"name":"c1","type":["null",{"type":"record","name":"record0","namespace":"com.materialize.sink","fields":[{"name":"x","type":["null","int"],"default":null},{"name":"y","type":["null","int"],"default":null}]}],"default":null},{"name":"c2","type":"string"},{"name":"c3","type":["null",{"type":"map","values":["null","boolean"]}],"default":null},{"name":"c4","type":["null",{"type":"array","items":["null",{"type":"record","name":"record1","namespace":"com.materialize.sink","fields":[{"name":"x","type":["null","int"],"default":null},{"name":"y","type":["null","int"],"default":null}]}]}],"default":null}]}

> CREATE SINK sink2
  IN CLUSTER ${arg.single-replica-cluster}
  FROM v
  INTO KAFKA CONNECTION kafka_conn (TOPIC 'testdrive-sink2-${testdrive.seed}')
  KEY (c2) NOT ENFORCED
  FORMAT AVRO USING CONFLUENT SCHEMA REGISTRY CONNECTION csr_conn
  (
    NULL DEFAULTS = FALSE
  )
  ENVELOPE UPSERT

$ schema-registry-verify schema-type=avro subject=testdrive-sink2-${testdrive.seed}-value
{"type":"record","name":"envelope","fields":[{"name":"c1","type":["null",{"type":"record","name":"record0","namespace":"com.materialize.sink","fields":[{"name":"x","type":["null","int"]},{"name":"y","type":["null","int"]}]}]},{"name":"c2","type":"string"},{"name":"c3","type":["null",{"type":"map","values":["null","boolean"]}]},{"name":"c4","type":["null",{"type":"array","items":["null",{"type":"record","name":"record1","namespace":"com.materialize.sink","fields":[{"name":"x","type":["null","int"]},{"name":"y","type":["null","int"]}]}]}]}]}

# errors
! CREATE SINK bad_sink
  IN CLUSTER ${arg.single-replica-cluster}
  FROM v
  INTO KAFKA CONNECTION kafka_conn (TOPIC 'testdrive-sink1-${testdrive.seed}')
  KEY (c2) NOT ENFORCED
  FORMAT AVRO USING CONFLUENT SCHEMA REGISTRY CONNECTION csr_conn
  (
    NULL DEFAULTS = "some_value"
  )
  ENVELOPE UPSERT
contains: invalid NULL DEFAULTS: cannot use value as boolean

! CREATE SINK bad_sink
  IN CLUSTER ${arg.single-replica-cluster}
  FROM v
  INTO KAFKA CONNECTION kafka_conn (TOPIC 'testdrive-sink1-${testdrive.seed}')
  KEY (c2) NOT ENFORCED
  FORMAT AVRO USING CONFLUENT SCHEMA REGISTRY CONNECTION csr_conn
  (
    NULL DEFAULTS = ""
  )
  ENVELOPE UPSERT
contains: Expected option value, found identifier ""

! CREATE SINK bad_sink
  IN CLUSTER ${arg.single-replica-cluster}
  FROM v
  INTO KAFKA CONNECTION kafka_conn (TOPIC 'testdrive-sink1-${testdrive.seed}')
  KEY (c2) NOT ENFORCED
  FORMAT AVRO USING CONFLUENT SCHEMA REGISTRY CONNECTION csr_conn
  (
    NULL DEFAULTS = NULL
  )
  ENVELOPE UPSERT
contains: invalid NULL DEFAULTS: cannot use value as boolean

! CREATE SINK bad_sink
  IN CLUSTER ${arg.single-replica-cluster}
  FROM v
  INTO KAFKA CONNECTION kafka_conn (TOPIC 'testdrive-sink1-${testdrive.seed}')
  KEY (c2) NOT ENFORCED
  FORMAT AVRO USING CONFLUENT SCHEMA REGISTRY CONNECTION csr_conn
  (
    NULL DEFAULTS,
    NULL DEFAULTS = TRUE
  )
  ENVELOPE UPSERT
contains: NULL DEFAULTS specified more than once
