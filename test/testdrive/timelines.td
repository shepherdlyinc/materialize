# Copyright Materialize, Inc. and contributors. All rights reserved.
#
# Use of this software is governed by the Business Source License
# included in the LICENSE file at the root of this repository.
#
# As of the Change Date specified in that file, in accordance with
# the Business Source License, use of this software will be governed
# by the Apache License, Version 2.0.

$ postgres-execute connection=postgres://mz_system:materialize@${testdrive.materialize-internal-sql-addr}
ALTER SYSTEM SET enable_envelope_materialize = true

$ postgres-execute connection=postgres://mz_system:materialize@${testdrive.materialize-internal-sql-addr}
ALTER SYSTEM SET enable_create_source_denylist_with_options = true

# Test various joins and how they interact with timeline checks.

$ kafka-create-topic topic=input-system

> CREATE CONNECTION kafka_conn
  TO KAFKA (BROKER '${testdrive.kafka-addr}', SECURITY PROTOCOL PLAINTEXT);

> CREATE SOURCE source_system
  IN CLUSTER ${arg.single-replica-cluster}
  FROM KAFKA CONNECTION kafka_conn (TOPIC 'testdrive-input-system-${testdrive.seed}')
  FORMAT BYTES

> CREATE SOURCE source_system_user
  IN CLUSTER ${arg.single-replica-cluster}
  FROM KAFKA CONNECTION kafka_conn (TOPIC 'testdrive-input-system-${testdrive.seed}')
  FORMAT BYTES
  WITH (TIMELINE '${testdrive.seed}-timelines')

$ set schema=[
  {
    "type": "array",
    "items": {
      "type": "record",
      "name": "update",
      "namespace": "com.materialize.cdc",
      "fields": [
        {
          "name": "data",
          "type": {
            "type": "record",
            "name": "data",
            "fields": [
              {
                "name": "id",
                "type": "long"
              },
              {
                "name": "price",
                "type": [
                  "null",
                  "int"
                ]
              }
            ]
          }
        },
        {
          "name": "time",
          "type": "long"
        },
        {
          "name": "diff",
          "type": "long"
        }
      ]
    }
  },
  {
    "type": "record",
    "name": "progress",
    "namespace": "com.materialize.cdc",
    "fields": [
      {
        "name": "lower",
        "type": {
          "type": "array",
          "items": "long"
        }
      },
      {
        "name": "upper",
        "type": {
          "type": "array",
          "items": "long"
        }
      },
      {
        "name": "counts",
        "type": {
          "type": "array",
          "items": {
            "type": "record",
            "name": "counts",
            "fields": [
              {
                "name": "time",
                "type": "long"
              },
              {
                "name": "count",
                "type": "long"
              }
            ]
          }
        }
      }
    ]
  }
  ]

$ kafka-create-topic topic=input-cdcv2

$ kafka-ingest format=avro topic=input-cdcv2 schema=${schema}
{"array":[{"data":{"id":5,"price":{"int":10}},"time":5,"diff":1}]}
{"array":[{"data":{"id":5,"price":{"int":12}},"time":4,"diff":1}]}
{"array":[{"data":{"id":5,"price":{"int":12}},"time":5,"diff":-1}]}

> CREATE SOURCE source_cdcv2
  IN CLUSTER ${arg.single-replica-cluster}
  FROM KAFKA CONNECTION kafka_conn (TOPIC 'testdrive-input-cdcv2-${testdrive.seed}')
  FORMAT AVRO USING SCHEMA '${schema}'
  ENVELOPE MATERIALIZE

! CREATE SOURCE source_cdcv2_system
  IN CLUSTER ${arg.single-replica-cluster}
  FROM KAFKA CONNECTION kafka_conn (TOPIC 'testdrive-input-cdcv2-${testdrive.seed}')
  FORMAT AVRO USING SCHEMA '${schema}'
  ENVELOPE MATERIALIZE
  WITH (TIMELINE 'mz_foo')
contains:unacceptable timeline name "mz_foo"

> CREATE SOURCE source_cdcv2_system
  IN CLUSTER ${arg.single-replica-cluster}
  FROM KAFKA CONNECTION kafka_conn (TOPIC 'testdrive-input-cdcv2-${testdrive.seed}')
  FORMAT AVRO USING SCHEMA '${schema}'
  ENVELOPE MATERIALIZE
  WITH (TIMELINE 'mz_epoch_ms')

> CREATE SOURCE source_cdcv2_user
  IN CLUSTER ${arg.single-replica-cluster}
  FROM KAFKA CONNECTION kafka_conn (TOPIC 'testdrive-input-cdcv2-${testdrive.seed}')
  FORMAT AVRO USING SCHEMA '${schema}'
  ENVELOPE MATERIALIZE
  WITH (TIMELINE '${testdrive.seed}-timelines')

> CREATE TABLE input_table (a bigint);

> CREATE VIEW input_values_view AS VALUES (1), (2), (3);

> CREATE MATERIALIZED VIEW input_values_mview AS VALUES (1), (2), (3);

! CREATE MATERIALIZED VIEW must_fail (a, b, c) AS SELECT * FROM source_system, source_cdcv2;
contains:multiple timelines within one dataflow are not supported

# Verify that user timelines don't allow things to be joinable with their non-user versions.
! CREATE MATERIALIZED VIEW must_fail (a, b) AS SELECT * FROM source_system, source_system_user;
contains:multiple timelines within one dataflow are not supported

# Can join static view with anything.
> CREATE VIEW values_table_view AS SELECT * FROM input_values_view, input_table;
> CREATE VIEW values_values_view (a, b) AS SELECT * FROM input_values_view, input_values_mview LIMIT 0;
> CREATE VIEW values_system_view AS SELECT * FROM input_values_view, source_system;
> CREATE VIEW values_system_user_view AS SELECT * FROM input_values_view, source_system_user;
> CREATE VIEW values_cdcv2_view AS SELECT * FROM input_values_view, source_cdcv2;
> CREATE VIEW values_mz_catalog_view (a, b, c, d, e, f, g, h, i, j, k)
  AS SELECT mz_relations.id, mz_relations.oid, mz_relations.schema_id, mz_relations.name, mz_relations.type, input_values_view.column1, mz_views.id, mz_views.oid, mz_views.schema_id, mz_views.name, mz_views.definition
  FROM mz_relations, input_values_view, mz_views;

# In case the environment has other replicas
> SET cluster_replica = r1

> SELECT count(*) FROM (SELECT count(*) FROM input_values_view, mz_internal.mz_dataflow_operators);
1

# System sources, tables, and logs should be joinable with eachother.
> SELECT count(*) FROM (SELECT count(*) FROM mz_relations, mz_views, mz_internal.mz_dataflow_operators);
1

# System things should be joinable only with system sources.
! CREATE VIEW must_fail (a, b, c, d, e, f, g, h, i, j, k, l)
  AS SELECT mz_relations.id, mz_relations.oid, mz_relations.schema_id, mz_relations.name, mz_relations.type, mz_views.id, mz_views.oid, mz_views.schema_id, mz_views.name, mz_views.definition, source_cdcv2.id, source_cdcv2.price
  FROM mz_relations, mz_views, source_cdcv2;
contains:multiple timelines within one dataflow are not supported
> CREATE VIEW various_system_no_cdcv2 (a, b, c, d, e, f, g, h, i, j, k)
  AS SELECT mz_relations.id, mz_relations.oid, mz_relations.schema_id, mz_relations.name, mz_relations.type, mz_views.id, mz_views.oid, mz_views.schema_id, mz_views.name, mz_views.definition, source_system.data
  FROM mz_relations, mz_views, source_system;

> CREATE VIEW various_system_table (a, b, c, d, e, f, g, h, i, j, k)
  AS SELECT mz_relations.id, mz_relations.oid, mz_relations.schema_id, mz_relations.name, mz_relations.type, mz_views.id, mz_views.oid, mz_views.schema_id, mz_views.name, mz_views.definition, input_table.a
  FROM mz_relations, mz_views, input_table;

# EXPLAIN should complain too.
! EXPLAIN SELECT * FROM source_system, source_cdcv2;
contains:multiple timelines within one dataflow are not supported

# Can join user-specified timelines.
> CREATE MATERIALIZED VIEW source_system_cdcv2_user (a, b, c) AS SELECT * FROM source_system_user, source_cdcv2_user;

# CDCv2 can only be joined with system time stuff if specified
> CREATE MATERIALIZED VIEW source_cdcv2_table_system AS SELECT * FROM source_cdcv2_system, input_table;
! CREATE MATERIALIZED VIEW must_fail AS SELECT * FROM source_cdcv2, input_table;
contains:multiple timelines within one dataflow are not supported

# Verify that if the transaction starts on some timeline (epoch ms here),
# things outside that are not there due to timedomain reasons.
> BEGIN;
> SELECT * FROM input_table;
! SELECT * FROM source_cdcv2;
contains:Transactions can only reference objects in the same timedomain
> ROLLBACK;
