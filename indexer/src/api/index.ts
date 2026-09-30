// Ponder's built-in API server. The public REST API is services/api, which reads the same tables through the views
// schema. OFF-07: Ponder's SQL-over-HTTP (/sql) and GraphQL run arbitrary reads on the database the API and keeper
// share, so they are mounted only with INDEXER_QUERY_API=1 (local debugging), and the indexer's port stays on the
// private network. Ponder's own /health, /ready and /status stay.
import { db } from "ponder:api";
import schema from "ponder:schema";
import { Hono } from "hono";
import { client, graphql } from "ponder";

const app = new Hono();
if (process.env.INDEXER_QUERY_API === "1") {
  app.use("/sql/*", client({ db, schema }));
  app.use("/graphql", graphql({ db, schema }));
}
export default app;
