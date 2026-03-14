# Neon Branch Topology

The Stacks uses a three-tier Neon branch hierarchy to isolate production data from preview environments.

## Branch Hierarchy

```
main                    <- production; migrations only; no seeds
└── staging             <- fixture data only; parent for all preview branches
     └── preview/<pr>   <- ephemeral; created per PR by deploy-preview.sh; destroyed on cleanup
```

## Why Three Tiers?

Neon branches are copy-on-write clones of their parent. Without the `staging` intermediary, every preview branch would clone `main` — inheriting all production user data. The `staging` branch contains only seed/fixture data (the `owner@thestacks.app` and `user@thestacks.app` test accounts), ensuring preview environments never expose real user information.

## Branch Lifecycle

| Branch | Created by | Contains | Destroyed |
|--------|-----------|----------|-----------|
| `main` | Neon project setup | Production data + migrations | Never |
| `staging` | One-time manual setup | Fixture data (seeds) | Never (manually maintained) |
| `preview/<branch>` | `deploy-preview.sh` | Inherited fixture data | `cleanup-preview.sh` (or PR merge) |

## Configuration

| Env var | Default | Description |
|---------|---------|-------------|
| `NEON_PARENT_BRANCH` | `staging` | Name of the parent branch for preview creation |
| `NEON_PROJECT_ID` | — | Neon project ID |
| `NEON_API_KEY` | — | Neon API key for branch management |

## Setting Up the Staging Branch

1. Create the branch in the Neon console or via CLI:
   ```bash
   neon branches create --name staging --project-id $NEON_PROJECT_ID
   ```

2. Run migrations against the staging branch.

3. Seed the staging branch with fixture data:
   ```bash
   fly ssh console --app stacks-core -C "ALLOW_SEEDS=true /app/bin/core eval 'Stacks.Release.seed()'"
   ```
   (Or connect directly to the staging branch's connection string and run seeds.)

4. All future preview branches will inherit this data automatically.
