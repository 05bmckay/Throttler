# Throttle: HubSpot Workflow Action Throttling System

## Overview

Throttle is an Elixir Phoenix application that implements a custom HubSpot workflow action for throttling requests. It uses Redis for queue management and PostgreSQL for storing OAuth tokens, action executions, and throttle configurations.

## System Components

1. **Phoenix Web Interface**: Handles incoming requests from HubSpot and provides API endpoints for managing throttle configurations.
2. **Throttle Core**: Manages the business logic for throttling, including queue management and action execution.
3. **OAuth Manager**: Handles secure storage and retrieval of OAuth tokens.
4. **Redis Manager**: Interfaces with Redis for queue management.
5. **Database (PostgreSQL)**: Stores OAuth tokens, action executions, and throttle configurations.
6. **Oban**: Manages background job processing for executing throttled actions.

## Prerequisites

- Elixir 1.11+
- Erlang 23+
- Phoenix 1.5+
- PostgreSQL 12+
- Redis 6+
- HubSpot developer account and app

## Setup Guide

Follow these steps to set up the Throttle application in a new environment:

1. **Clone the repository:**
   ```
   git clone https://github.com/yourusername/throttle.git
   cd throttle
   ```

2. **Install dependencies:**
   ```
   mix deps.get
   ```

3. **Set up environment variables:**
   Create a `.env` file in the project root with the following content:
   ```
   export SECRET_KEY_BASE=<generate-with-mix-phx-gen-secret>
   export DATABASE_URL=ecto://USER:PASS@HOST/DATABASE
   export REDIS_URL=redis://localhost:6379
   export HUBSPOT_CLIENT_ID=your_hubspot_client_id
   export HUBSPOT_CLIENT_SECRET=your_hubspot_client_secret
   export ENCRYPTION_KEY=<32-byte-encryption-key>
   ```
   Source the file:
   ```
   source .env
   ```

4. **Create and migrate the database:**
   ```
   mix ecto.create
   mix ecto.migrate
   ```

5. **Start the Phoenix server:**
   ```
   mix phx.server
   ```

6. **Set up HubSpot app:**
   - Create a new app in your HubSpot developer account
   - Set up a custom workflow action pointing to your Throttle application's endpoint (e.g., `https://your-app-url.com/api/hubspot/action`)
   - Configure the necessary scopes for your app

7. **Configure throttle settings:**
   Use the `/api/config` endpoint to set up throttle configurations for different HubSpot portals and actions.

## API Endpoints

- `POST /api/hubspot/action`: Receives actions from HubSpot
- `POST /api/config`: Creates or updates a throttle configuration
- `GET /api/config/:portal_id/:action_id`: Retrieves a throttle configuration

## Development

1. **Running tests:**
   ```
   mix test
   ```

2. **Starting an IEx session with the application:**
   ```
   iex -S mix phx.server
   ```

3. **Generating documentation:**
   ```
   mix docs
   ```

## Deployment

1. **Build a release:**
   ```
   MIX_ENV=prod mix release
   ```

2. **Deploy the release to your server**

3. **Set up environment variables on your server**

4. **Run database migrations:**
   ```
   _build/prod/rel/throttle/bin/throttle eval "Throttle.Release.migrate"
   ```

5. **Start the application:**
   ```
   _build/prod/rel/throttle/bin/throttle start
   ```

## Monitoring and Maintenance

- Monitor Redis for queue health and performance
- Check PostgreSQL for action execution history and OAuth token status
- Use Oban's dashboard for job processing insights
- Implement logging and error tracking for production environments

## Troubleshooting

- Check application logs for error messages
- Verify Redis connection and queue status
- Ensure database migrations are up to date
- Validate HubSpot app configuration and OAuth token validity

## Security Considerations

- OAuth tokens are encrypted at rest in the database
- All sensitive configuration is managed through environment variables
- Regularly rotate encryption keys and HubSpot client secrets
- Ensure all communication uses HTTPS

## Contributing

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/AmazingFeature`)
3. Commit your changes (`git commit -m 'Add some AmazingFeature'`)
4. Push to the branch (`git push origin feature/AmazingFeature`)
5. Open a Pull Request

## License

[Specify your license here]

## Support

For support, please open an issue in the GitHub repository or contact [your contact information].
