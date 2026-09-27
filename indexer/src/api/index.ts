// Ponder's built-in API server: SQL-over-HTTP and GraphQL for the indexed tables. The public REST
// API is services/api, which reads the same tables through the `indexer` views schema.
import { db } from "ponder:api";
import schema from "ponder:schema";
import { Hono } from "hono";
import { client, graphql } from "ponder";

const app = new Hono();
app.use("/sql/*", client({ db, schema }));
app.use("/graphql", graphql({ db, schema }));
export default app;
