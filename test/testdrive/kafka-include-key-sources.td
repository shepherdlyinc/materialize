# Copyright Materialize, Inc. and contributors. All rights reserved.
#
# Use of this software is governed by the Business Source License
# included in the LICENSE file at the root of this repository.
#
# As of the Change Date specified in that file, in accordance with
# the Business Source License, use of this software will be governed
# by the Apache License, Version 2.0.

$ set conflictkeyschema={
    "type": "record",
    "name": "Key",
    "fields": [
        {"name": "id", "type": "long"}
    ]
  }

$ set schema={
    "name": "row",
    "type": "record",
    "fields": [
      {"name": "id", "type": "long"},
      {"name": "b", "type": "long"}
    ]
  }

$ kafka-create-topic topic=avro-data partitions=1
$ kafka-ingest format=avro key-format=avro topic=avro-data key-schema=${conflictkeyschema} schema=${schema} timestamp=1
{"id": 1} {"id": 2, "b": 3}

> CREATE CONNECTION kafka_conn
  TO KAFKA (BROKER '${testdrive.kafka-addr}', SECURITY PROTOCOL PLAINTEXT);

! CREATE SOURCE missing_key_format
  IN CLUSTER ${arg.single-replica-cluster}
  FROM KAFKA CONNECTION kafka_conn (TOPIC 'testdrive-avro-data-${testdrive.seed}')
  FORMAT AVRO USING SCHEMA '${schema}'
  INCLUDE KEY
contains:INCLUDE KEY requires specifying KEY FORMAT .. VALUE FORMAT, got bare FORMAT

! CREATE SOURCE missing_key_format
  IN CLUSTER ${arg.single-replica-cluster}
  FROM KAFKA CONNECTION kafka_conn (TOPIC 'testdrive-avro-data-${testdrive.seed}')
  FORMAT AVRO USING SCHEMA '${schema}'
  INCLUDE KEY AS key_col
contains:INCLUDE KEY requires specifying KEY FORMAT .. VALUE FORMAT, got bare FORMAT

> CREATE CONNECTION IF NOT EXISTS csr_conn TO CONFLUENT SCHEMA REGISTRY (
    URL '${testdrive.schema-registry-url}'
  );

# "Bare" format works when the key format is in a registry
> CREATE SOURCE bareformatconfluent
  IN CLUSTER ${arg.single-replica-cluster}
  FROM KAFKA CONNECTION kafka_conn (TOPIC
  'testdrive-avro-data-${testdrive.seed}')
  FORMAT AVRO USING CONFLUENT SCHEMA REGISTRY CONNECTION csr_conn
  INCLUDE KEY AS named
  ENVELOPE UPSERT

> SELECT * from bareformatconfluent
named         id       b
------------------------
1             2        3

! CREATE SOURCE avro_data_conflict
  IN CLUSTER ${arg.single-replica-cluster}
  FROM KAFKA CONNECTION kafka_conn (TOPIC 'testdrive-avro-data-${testdrive.seed}')
  KEY FORMAT AVRO USING SCHEMA '${conflictkeyschema}'
  VALUE FORMAT AVRO USING SCHEMA '${schema}'
  INCLUDE KEY
contains: column "id" specified more than once

> CREATE SOURCE avro_data_explicit (key_id, id, b)
  IN CLUSTER ${arg.single-replica-cluster}
  FROM KAFKA CONNECTION kafka_conn (TOPIC 'testdrive-avro-data-${testdrive.seed}')
  KEY FORMAT AVRO USING SCHEMA '${conflictkeyschema}'
  VALUE FORMAT AVRO USING SCHEMA '${schema}'
  INCLUDE KEY

> SELECT key_id, id, b FROM avro_data_explicit
key_id id b
------------
1 2 3

> CREATE SOURCE include_partition
  IN CLUSTER ${arg.single-replica-cluster}
  FROM KAFKA CONNECTION kafka_conn (TOPIC 'testdrive-avro-data-${testdrive.seed}')
  FORMAT AVRO USING SCHEMA '${schema}'
  INCLUDE PARTITION

> SELECT * FROM include_partition
id b partition
--------------
2 3 0

> CREATE SOURCE avro_data_as
  IN CLUSTER ${arg.single-replica-cluster}
  FROM KAFKA CONNECTION kafka_conn (TOPIC 'testdrive-avro-data-${testdrive.seed}')
  KEY FORMAT AVRO USING SCHEMA '${conflictkeyschema}'
  VALUE FORMAT AVRO USING SCHEMA '${schema}'
  INCLUDE KEY AS renamed_id

> SELECT * FROM avro_data_as
renamed_id id b
------------
1 2 3

> CREATE SOURCE avro_avro_data (key_id, id, b)
  IN CLUSTER ${arg.single-replica-cluster}
  FROM KAFKA CONNECTION kafka_conn (TOPIC 'testdrive-avro-data-${testdrive.seed}')
  KEY FORMAT AVRO USING SCHEMA '${conflictkeyschema}'
  VALUE FORMAT AVRO USING SCHEMA '${schema}'
  INCLUDE KEY

> CREATE SOURCE avro_data_upsert
  IN CLUSTER ${arg.single-replica-cluster}
  FROM KAFKA CONNECTION kafka_conn (TOPIC 'testdrive-avro-data-${testdrive.seed}')
  KEY FORMAT AVRO USING SCHEMA '${conflictkeyschema}'
  VALUE FORMAT AVRO USING SCHEMA '${schema}'
  INCLUDE KEY AS renamed
  ENVELOPE UPSERT

> SELECT * FROM avro_data_upsert
renamed id b
------------
1 2 3

$ set multikeyschema={
    "type": "record",
    "name": "Key",
    "fields": [
      {"name": "id", "type": "long"},
      {"name": "geo", "type": "string"}
    ]
  }

$ set noconflictschema={
    "name": "row",
    "type": "record",
    "fields": [
      {"name": "a", "type": "long"}
    ]
  }

$ kafka-create-topic topic=avro-data-record
$ kafka-ingest format=avro key-format=avro topic=avro-data-record key-schema=${multikeyschema} schema=${noconflictschema} timestamp=1
{"id": 1, "geo": "nyc"} {"a": 99}
$ kafka-ingest format=avro topic=avro-data-record schema=${noconflictschema} timestamp=2 omit-key=true
{"a": 88}

> CREATE SOURCE avro_key_record_flattened
  IN CLUSTER ${arg.single-replica-cluster}
  FROM KAFKA CONNECTION kafka_conn (TOPIC 'testdrive-avro-data-record-${testdrive.seed}')
  KEY FORMAT AVRO USING SCHEMA '${multikeyschema}'
  VALUE FORMAT AVRO USING SCHEMA '${noconflictschema}'
  INCLUDE KEY
  ENVELOPE NONE

> SELECT * FROM avro_key_record_flattened ORDER BY a ASC
id     geo    a
----------------
<null> <null> 88
1      nyc    99

> CREATE SOURCE avro_key_record_renamed
  IN CLUSTER ${arg.single-replica-cluster}
  FROM KAFKA CONNECTION kafka_conn (TOPIC 'testdrive-avro-data-record-${testdrive.seed}')
  KEY FORMAT AVRO USING SCHEMA '${multikeyschema}'
  VALUE FORMAT AVRO USING SCHEMA '${noconflictschema}'
  INCLUDE KEY AS named
  ENVELOPE NONE

> SELECT (named).id as named_id, (named).geo as named_geo, a FROM avro_key_record_renamed ORDER BY a ASC
named_id named_geo a
---------------------
<null>   <null>    88
1        nyc       99

! CREATE SOURCE avro_debezium
  IN CLUSTER ${arg.single-replica-cluster}
  FROM KAFKA CONNECTION kafka_conn (TOPIC 'testdrive-avro-dbz-${testdrive.seed}')
  KEY FORMAT AVRO USING SCHEMA '${noconflictschema}'
  VALUE FORMAT AVRO USING SCHEMA '${schema}'
  INCLUDE KEY AS named
  ENVELOPE debezium
contains:Cannot use INCLUDE KEY with ENVELOPE DEBEZIUM: Debezium values include all keys.

# formats: TEXT and REGEX
$ kafka-create-topic topic=textsrc partitions=1

$ kafka-ingest topic=textsrc format=bytes key-format=bytes key-terminator=:
one,1:horse,apple
two,2:bee,honey
:cow,grass

> CREATE SOURCE textsrc
  IN CLUSTER ${arg.single-replica-cluster}
  FROM KAFKA CONNECTION kafka_conn (TOPIC 'testdrive-textsrc-${testdrive.seed}')
  KEY FORMAT TEXT
  VALUE FORMAT TEXT
  INCLUDE KEY

> SELECT * FROM textsrc
key    text
-------------------
one,1  horse,apple
two,2  bee,honey
<null> cow,grass

> CREATE SOURCE regexvalue
  IN CLUSTER ${arg.single-replica-cluster}
  FROM KAFKA CONNECTION kafka_conn (TOPIC 'testdrive-textsrc-${testdrive.seed}')
  KEY FORMAT TEXT
  VALUE FORMAT REGEX '(?P<animal>[^,]+),(?P<food>\w+)'
  INCLUDE KEY

> SELECT * FROM regexvalue
key   animal  food
--------------------
one,1  horse  apple
two,2  bee    honey
<null> cow    grass

> CREATE SOURCE regexboth
  IN CLUSTER ${arg.single-replica-cluster}
  FROM KAFKA CONNECTION kafka_conn (TOPIC 'testdrive-textsrc-${testdrive.seed}')
  KEY FORMAT REGEX '(?P<id_name>[^,]+),(?P<id>\w+)'
  VALUE FORMAT REGEX '(?P<animal>[^,]+),(?P<food>\w+)'
  INCLUDE KEY

> SELECT * FROM regexboth
id_name id     animal food
---------------------------
one     1      horse  apple
two     2      bee    honey
<null>  <null> cow    grass

> CREATE SOURCE regexbothnest
  IN CLUSTER ${arg.single-replica-cluster}
  FROM KAFKA CONNECTION kafka_conn (TOPIC 'testdrive-textsrc-${testdrive.seed}')
  KEY FORMAT REGEX '(?P<id_name>[^,]+),(?P<id>\w+)'
  VALUE FORMAT REGEX '(?P<animal>[^,]+),(?P<food>\w+)'
  INCLUDE KEY AS nest

> SELECT (nest).id_name, (nest).id, animal FROM regexbothnest
id_name id     animal
--------------------
<null>  <null> cow
one     1      horse
two     2      bee

$ file-append path=test.proto
syntax = "proto3";

message Key {
    string id = 1;
}

message KeyComplex {
    int32 id1 = 1;
    int32 id2 = 2;
}

message Value {
    int32 measurement = 1;
}

$ protobuf-compile-descriptors inputs=test.proto output=test.proto set-var=test-schema

$ kafka-create-topic topic=proto partitions=1

$ kafka-ingest topic=proto
  key-format=protobuf key-descriptor-file=test.proto key-message=Key
  format=protobuf descriptor-file=test.proto message=Value
{"id": "a"} {"measurement": 10}

$ kafka-ingest topic=proto format=protobuf descriptor-file=test.proto message=Value omit-key=true
{"measurement": 11}

> CREATE SOURCE input_proto
  IN CLUSTER ${arg.single-replica-cluster}
  FROM KAFKA CONNECTION kafka_conn (TOPIC 'testdrive-proto-${testdrive.seed}')
  KEY FORMAT PROTOBUF MESSAGE '.Key' USING SCHEMA '${test-schema}'
  VALUE FORMAT PROTOBUF MESSAGE '.Value' USING SCHEMA '${test-schema}'
  INCLUDE KEY

> SELECT * FROM input_proto
id     measurement
-------------------
a      10
<null> 11

$ kafka-create-topic topic=proto-structured partitions=1

$ kafka-ingest topic=proto-structured
  key-format=protobuf key-descriptor-file=test.proto key-message=KeyComplex
  format=protobuf descriptor-file=test.proto message=Value
{"id1": 1, "id2": 2} {"measurement": 10}

> CREATE SOURCE input_proto_structured
  IN CLUSTER ${arg.single-replica-cluster}
  FROM KAFKA CONNECTION kafka_conn (TOPIC 'testdrive-proto-structured-${testdrive.seed}')
  KEY FORMAT PROTOBUF MESSAGE '.KeyComplex' USING SCHEMA '${test-schema}'
  VALUE FORMAT PROTOBUF MESSAGE '.Value' USING SCHEMA '${test-schema}'
  INCLUDE KEY AS key

> SELECT key::text, (key).id1, (key).id2, measurement FROM input_proto_structured
key    id1  id2  measurement
----------------------------
(1,2)  1    2    10

#
# Regression test for #20981
#

# For UPSERT sources with INCLUDE KEY, we expect the queries to
# take advantage of the uniqueness propery of the key column.

? EXPLAIN SELECT DISTINCT named FROM bareformatconfluent;
Explained Query:
  Project (#0)
    ReadStorage materialize.public.bareformatconfluent

> CREATE DEFAULT INDEX ON bareformatconfluent;

? EXPLAIN SELECT DISTINCT named FROM bareformatconfluent;
Explained Query (fast path):
  Project (#0)
    ReadIndex on=materialize.public.bareformatconfluent bareformatconfluent_primary_idx=[*** full scan ***]

Used Indexes:
  - materialize.public.bareformatconfluent_primary_idx (*** full scan ***)

> CREATE SOURCE envelope_none_with_key
  IN CLUSTER ${arg.single-replica-cluster}
  FROM KAFKA CONNECTION kafka_conn (TOPIC
  'testdrive-avro-data-${testdrive.seed}')
  KEY FORMAT AVRO USING SCHEMA '${conflictkeyschema}'
  VALUE FORMAT AVRO USING SCHEMA '${schema}'
  INCLUDE KEY AS named
  ENVELOPE NONE

# For ENVELOPE NONE with INCLUDE KEY, uniqueness is not guaranteed,
# so we expect that query plans will contain an explicit Distinct on

? EXPLAIN SELECT DISTINCT named FROM envelope_none_with_key;
Explained Query:
  Distinct project=[#0] monotonic
    Project (#0)
      ReadStorage materialize.public.envelope_none_with_key

> CREATE DEFAULT INDEX ON envelope_none_with_key;

? EXPLAIN SELECT DISTINCT named FROM envelope_none_with_key;
Explained Query:
  Distinct project=[#0] monotonic
    Project (#0)
      ReadIndex on=envelope_none_with_key envelope_none_with_key_primary_idx=[*** full scan ***]

Used Indexes:
  - materialize.public.envelope_none_with_key_primary_idx (*** full scan ***)
