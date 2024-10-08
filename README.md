# Throttle: HubSpot Workflow Action Throttling System

## Overview

Throttle is an Elixir Phoenix application designed to implement custom HubSpot workflow actions, specifically for throttling requests. This repository serves as a robust template for building out other HubSpot Workflow action backends, handling common tasks such as catching webhooks, managing OAuth tokens, and processing background jobs.

### Why Use This Repository?

1. **Comprehensive Setup**: Includes everything needed to get started with HubSpot workflow actions, from OAuth management to webhook handling.
2. **Scalable Architecture**: Built with Elixir and Phoenix, known for their concurrency and fault-tolerance, making it ideal for high-throughput applications.
3. **Extensible**: Easily extendable to add more workflow actions or integrate with other services.
4. **Best Practices**: Implements best practices for security, logging, and error handling.

## System Components

1. **Phoenix Web Interface**: Handles incoming requests from HubSpot and provides API endpoints for managing throttle configurations.
2. **Throttle Core**: Manages the business logic for throttling, including queue management and action execution.
3. **OAuth Manager**: Handles secure storage and retrieval of OAuth tokens.
4. **Database (PostgreSQL)**: Stores OAuth tokens, action executions, and throttle configurations.
5. **Oban**: Manages background job processing for executing throttled actions.

## Prerequisites

- Elixir 1.11+
- Erlang 23+
- Phoenix 1.5+
- PostgreSQL 12+
- HubSpot developer account and app

## Setup Guide

Follow these steps to set up the Throttle application in a new environment:

### 1. Clone the Repository
```sh
git clone https://github.com/yourusername/throttle.git
cd throttle
```

### 2. Install Dependencies
```sh
mix deps.get
```

### 3. Set Up Environment Variables
Create a `.env` file in the project root with the following content:
```sh
export SECRET_KEY_BASE=<generate-with-mix-phx-gen-secret>
export DATABASE_URL=ecto://USER:PASS@HOST/DATABASE
export HUBSPOT_CLIENT_ID=your_hubspot_client_id
export HUBSPOT_CLIENT_SECRET=your_hubspot_client_secret
export ENCRYPTION_KEY=<32-byte-encryption-key>
```
Source the file:
```sh
source .env
```

### 4. Create and Migrate the Database
```sh
mix ecto.create
mix ecto.migrate
```

### 5. Start the Phoenix Server
```sh
mix phx.server
```

### 6. Set Up HubSpot App
- Create a new app in your HubSpot developer account.
- Set up a custom workflow action pointing to your Throttle application's endpoint (e.g., `https://your-app-url.com/api/hubspot/action`).
- Configure the necessary scopes for your app.

### 7. Configure Throttle Settings
Use the `/api/config` endpoint to set up throttle configurations for different HubSpot portals and actions.

## API Endpoints

- `POST /api/hubspot/action`: Receives actions from HubSpot.
- `POST /api/config`: Creates or updates a throttle configuration.
- `GET /api/config/:portal_id/:action_id`: Retrieves a throttle configuration.

## Development

### Running Tests
```sh
mix test
```

### Starting an IEx Session with the Application
```sh
iex -S mix phx.server
```

### Generating Documentation
```sh
mix docs
```

## Deployment

### Build a Release
```sh
MIX_ENV=prod mix release
```

### Deploy the Release to Your Server

### Set Up Environment Variables on Your Server

## Conclusion

Throttle provides a solid foundation for building HubSpot workflow action backends. By leveraging Elixir and Phoenix, it ensures high performance and scalability. Use this repository as a template to quickly get started with your own custom HubSpot workflow actions, handling everything from OAuth to webhook processing with ease.

## Support

For support, please open an issue in the GitHub repository or contact [your contact information].
