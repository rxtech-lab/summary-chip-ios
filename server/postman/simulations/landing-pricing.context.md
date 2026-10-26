Local fixture based on RxSubscription's `app/api/v1/catalog/route.ts` and
`lib/subscription/catalog-payload.ts`, inspected 2026-10-26. This is a contract
fixture; no published owner mock was pulled. It proves local behavior only.

From `server`:

```sh
postman simulation run postman/simulations/landing-pricing.sim.yaml --port 4912 --output ndjson
PRICING_SIMULATION_URL=http://localhost:4912/subscription bun run test tests/integration/landing-pricing.test.ts
RX_SUBSCRIPTION_URL=http://localhost:4912/subscription/catalog RX_SUBSCRIPTION_PRODUCTION_API_KEY=rxs_production_pricing-fixture bunx next dev --port 3106
```

The URL printed by the simulation is authoritative. Paths under `/subscription`
select `/catalog`, `/empty`, `/outage` or `/malformed`; each then accepts
`GET /api/v1/catalog?platform=web`. The fixed fixture key is not a credential.
The tests use real HTTP and check production key selection, web prices, empty
catalogs, invalid data and HTTP failure. Simulation request events establish
that the production client path reached the fixture. Live production catalog
configuration and App Store prices remain separate checks.
