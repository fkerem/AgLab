# Agriculture Grafana Lab Environment

This repository makes the university agriculture data-visualization lab reproducible for future instructors. It runs a Course VM first stack with TimescaleDB, Grafana, optional Caddy HTTPS, course lecture/lab/homework materials, agriculture sensor datasets, and scripts for per-student accounts.

The repo intentionally does not contain live credentials. Copy `.env.example` to `.env` and fill in local values on each deployment.

## System Requirements

Recommended Course VM:

- Ubuntu 22.04 LTS or newer
- 2 vCPU minimum, 4 vCPU recommended
- 4 GB RAM minimum, 8 GB recommended for larger classes
- 30 GB disk minimum
- Docker Engine
- Docker Compose v2
- Git
- Bash, curl, jq, OpenSSL
- Python 3.10 or newer for the CSV helper script
- Tailscale for private student access

Optional public HTTPS:

- A DNS name pointing at the VM
- Ports 80 and 443 open to the public internet
- A valid email address for Let's Encrypt notices

## Repository Layout

- `docker-compose.yml`: TimescaleDB, Grafana, and optional Caddy services.
- `.env.example`: Credential and deployment placeholders.
- `db/init/`: Database initialization SQL for TimescaleDB and demo data.
- `grafana/provisioning/`: Instructor datasource and dashboard provisioning.
- `grafana/dashboards/`: Provisioned instructor demo dashboard.
- `materials/lecture/`: Lecture PDF.
- `materials/in-lab/`: Guided in-lab assignment PDF.
- `materials/homework/`: Homework assignment PDF.
- `data/in-lab/`: Soil temperature CSV and pre-generated bulk SQL.
- `data/homework/`: Weather station homework CSV.
- `data/private/`: Optional local-only real datasets. This path is gitignored.
- `scripts/healthcheck.sh`: Service and database health checks.
- `scripts/provision_students.sh`: Creates student PostgreSQL and Grafana accounts.
- `scripts/csv_to_sql.py`: Typed CSV-to-SQL helper provided with the course materials.
- `scripts/csv_to_insert.py`: Converts CSV rows into inspectable PostgreSQL INSERT SQL.

## Quick Start

1. Clone or copy this repository onto the Course VM.

   ```bash
   git clone <repository-url> aglab-repro
   cd aglab-repro
   ```

2. Create the environment file.

   ```bash
   cp .env.example .env
   ```

3. Edit `.env` and replace every `CHANGE_ME` value.

   For a Tailscale deployment, set `BIND_IP` to:

   ```bash
   tailscale ip -4
   ```

   Required values:

   ```dotenv
   BIND_IP=<tailscale-ip-or-127.0.0.1>
   POSTGRES_PASSWORD=<strong-database-admin-password>
   GRAFANA_ADMIN_PASSWORD=<strong-grafana-admin-password>
   GRAFANA_DOMAIN=<tailscale-ip-or-hostname>
   GRAFANA_ROOT_URL=http://<tailscale-ip-or-127.0.0.1>:3000/
   STUDENT_COUNT=<number-of-student-accounts>
   ```

   Optional HTTPS values:

   ```dotenv
   DOMAIN=<course-hostname>
   LETSENCRYPT_EMAIL=<teacher-email>
   ```

4. Start the core services.

   ```bash
   docker compose pull
   docker compose up -d
   ```

5. Run the health check.

   ```bash
   scripts/healthcheck.sh
   ```

6. Provision student accounts.

   ```bash
   scripts/provision_students.sh
   ```

   The script writes generated student credentials to:

   ```text
   credentials/student_credentials.csv
   ```

   That file is gitignored. Distribute it only through a secure course channel.

## Access Information

Grafana:

```text
http://<BIND_IP>:3000
```

PostgreSQL / TimescaleDB:

```text
Host: <BIND_IP>
Port: 5432
Database: aglab
SSL/TLS: disabled for the private course network
```

Instructor database admin:

```text
Username: value of POSTGRES_USER in .env
Password: value of POSTGRES_PASSWORD in .env
```

Grafana admin:

```text
Username: value of GRAFANA_ADMIN_USER in .env
Password: value of GRAFANA_ADMIN_PASSWORD in .env
```

Student accounts:

```text
Username: student1, student2, ...
Password: generated in credentials/student_credentials.csv
PostgreSQL schema: s_student1, s_student2, ...
Grafana organization: org_student1, org_student2, ...
```

## Optional Public HTTPS

DNS is not required for the normal Tailscale workflow. If a public hostname is needed later:

1. Point the hostname's DNS A record to the VM public IP.
2. Set `DOMAIN` and `LETSENCRYPT_EMAIL` in `.env`.
3. Set `GRAFANA_DOMAIN` to the same hostname and `GRAFANA_ROOT_URL` to `https://<DOMAIN>/`.
4. Start the Caddy profile.

   ```bash
   docker compose --profile public_https up -d
   ```

5. Visit:

   ```text
   https://<DOMAIN>
   ```

If certificate renewal fails, verify that DNS points to the current VM and that inbound ports 80 and 443 are reachable from the internet.

## Student Provisioning Behavior

`scripts/provision_students.sh` uses `.env` and does the following for `student1` through `studentN`:

- Generates or reuses a password in `credentials/student_credentials.csv`.
- Creates or updates a PostgreSQL login role.
- Creates a private schema named `s_studentN`.
- Sets the student's PostgreSQL `search_path` to `s_studentN, public`.
- Creates or updates a Grafana user.
- Creates a Grafana organization named `org_studentN`.
- Adds the student as an Admin in their own Grafana organization.

By default, students create their own Grafana PostgreSQL datasource during the lab. To pre-create datasources for every student, set this in `.env` before running the script:

```dotenv
PREPROVISION_STUDENT_DATASOURCES=true
```

## Course Materials and Datasets

Included instructional materials:

- `materials/lecture/Lecture.pdf`
- `materials/in-lab/in-lab.pdf`
- `materials/homework/homework.pdf`

Included datasets:

- `data/in-lab/soil_temperature.csv`: soil temperature lab dataset, timestamp range July 1 to August 1, 2025.
- `data/in-lab/soil_temperature_bulk.sql`: pre-generated bulk insert SQL for the soil temperature lab dataset.
- `data/homework/weather_station_7_days.csv`: weather station homework dataset, timestamp range February 12 to February 19, 2026.

Students must set Grafana's dashboard time picker to a range that overlaps the dataset they are using.

## Lab CSV Workflow

Soil temperature table example:

```sql
CREATE TABLE soil_temperature (
  ts TIMESTAMPTZ NOT NULL,
  device_id TEXT NOT NULL,
  depth_cm INTEGER NOT NULL,
  temp_c NUMERIC(6,2),
  PRIMARY KEY (ts, device_id, depth_cm)
);

SELECT create_hypertable('soil_temperature', 'ts', if_not_exists => TRUE);
```

Generate INSERT SQL:

```bash
scripts/csv_to_sql.py data/in-lab/soil_temperature.csv \
  --table soil_temperature \
  --cols ts,device_id,depth_cm,temp_c \
  --text-cols ts,device_id \
  --int-cols depth_cm \
  --numeric-cols temp_c \
  > /tmp/soil_temperature_bulk.sql
```

Load it as a student:

```bash
psql -h <BIND_IP> -U student1 -d aglab -f /tmp/soil_temperature_bulk.sql
```

Or load the pre-generated SQL file:

```bash
psql -h <BIND_IP> -U student1 -d aglab -f data/in-lab/soil_temperature_bulk.sql
```

For additional local-only datasets, place copies under `data/private/` or another secure location and do not commit them unless the dataset is approved for redistribution.

## Common Operations

Show resolved Compose configuration:

```bash
docker compose config
```

Start services:

```bash
docker compose up -d
```

View logs:

```bash
docker compose logs -f --tail=100
```

Stop services without deleting data:

```bash
docker compose down
```

Delete all service data and start over:

```bash
scripts/reset_environment.sh --yes
```

Warning: reset deletes Docker volumes for PostgreSQL, Grafana, and Caddy.

## Troubleshooting

Empty Grafana panels:

- Check that the dashboard time range overlaps the dataset timestamps.
- Confirm queries use Grafana time macros such as `$__timeFilter(ts)`.
- Confirm the table exists in the student's schema.

Cannot connect to PostgreSQL:

- Confirm the student is connected to Tailscale.
- Confirm `BIND_IP` is the VM Tailscale IP.
- Confirm port `5432` is allowed on the Tailscale interface.
- Run `scripts/healthcheck.sh`.

Grafana login fails:

- Confirm the student is using the generated password from `credentials/student_credentials.csv`.
- Rerun `scripts/provision_students.sh` to reconcile missing users.

Public HTTPS fails:

- Confirm DNS points to the current VM public IP.
- Confirm ports 80 and 443 are open.
- Check Caddy logs with `docker compose logs caddy`.

## Security Notes

- Never commit `.env`.
- Never commit `credentials/student_credentials.csv`.
- Rotate credentials between course offerings.
- Use Tailscale as the default access path for students.
- Expose PostgreSQL only on the Tailscale interface, not on the public internet.
- Treat real sensor datasets as private unless they are explicitly cleared for redistribution.
