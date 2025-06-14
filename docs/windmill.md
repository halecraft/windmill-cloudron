Self-host Windmill

Self-host Windmill on your own infrastructure.

For small setups, use Docker and Docker Compose on a single instance. For larger and production use-cases, use our Helm chart to deploy on Kubernetes. You can also run Windmill workers on Windows without Docker.

Self-hosted Windmill

    Example of a self-hosted Windmill instance on localhost.


Windmill itself just requires 3 components:

    A Postgres database, which contains the entire state of Windmill, including the job queue.
    The Windmill container running in server mode (and replicated for high availability). It serves both the frontend and the API. It needs to connect to the database and is what is exposed publicly to serve the frontend. It does not need to communicate to the workers directly.
    The Windmill container running in worker mode (and replicated to handle more job throughput). It needs to connect to the database and does not communicate to the servers.

There are 3 optional components:

    Windmill LSP to provide intellisense on the Monaco web Editor.
    Windmill Multiplayer (Cloud & Enterprise Selfhosted only) to provide real time collaboration.
    A reverse proxy (caddy in our Docker compose) to the Windmill server, LSP and multiplayer in order to expose a single port to the outside world.

The docker-compose file below uses all six components, and we recommend handling TLS termination outside of the provided Caddy service..
Cloud provider-specific guides

For instances with specific cloud providers requirements:

    AWS, GCP, Azure
    Ubicloud
    Fly.io
    Hetzner, Fargate, Digital Ocean, Linode, Scaleway, Vultr, OVH, ...

If you have no specific requirements, see Docker.
AWS, GCP, Azure, Neon

We recommend using the Helm chart to deploy on managed Kubernetes. But for simplified setup, simply use the docker-compose (see below) on a single large instance and use a high number of replicas for the worker service.

The rule of thumb is 1 worker per 1vCPU and 1-2 GB of RAM. Cloud providers have managed load balancer services (ELB, GCLB, ALB) and managed database (RDS, Cloud SQL, Aurora, Postgres on Azure). We recommend disabling the db service in docker-compose and using an external database by setting the DATABASE_URL in the .env file for handling environment variables.

Windmill is compatible with AWS Aurora, GCP Cloud SQL, Azure and Neon serverless database.

Use the managed load balancer to point to your instance on the port you have chosen to expose in the caddy section of the docker-compose (by default 80). We recommend doing TLS termination and associating your domain on your managed load balancer. Once the domain name is chosen, set BASE_URL accordingly in .env. That is it for a minimal setup. Read about Worker groups to configure more finely your workers on more nodes and with different resources. Once done, be sure to setup SSO login with Azure AD, Google Workspace or GitHub if relevant.
AWS ECS

To be able to use the AWS APIs within Windmill on ECS containers, just whitelist the following environment variables in .env: WHITELIST_ENVS = "AWS_EXECUTION_ENV,AWS_CONTAINER_CREDENTIALS_RELATIVE_URI,AWS_DEFAULT_REGION,AWS_REGION"
Workers and worker groups
Worker Groups allow users to run scripts and flows on different machines with varying specifications.
Windmill on AWS EKS or ECS
Windmill can also be deployed on AWS EKS or ECS
Ubicloud

Ubicloud provides cost-efficient managed Kubernetes and Postgresql. They are a great compromise if you are cost sensitive but still want to get a multi-node Kubernetes Windmill setup. And they are open-source too as an infra layer on top of other cloud providers.
Ubicloud
Ubicloud Community-Contributed Guide.
Fly.io
Fly.io
Fly.io Community-Contributed Guide.
Render.com
Render.com
Render.com Setup Guide.
Hetzner, Fargate, Digital Ocean, Linode, Scaleway, Vultr, OVH, ...

Windmill works with those providers using the Docker containers and specific guides are in progress.
Docker
Setup Windmill on localhost

Self-host Windmill in less than a minute:

Using Docker and Caddy, Windmill can be deployed using 3 files: (docker-compose.yml, Caddyfile) and a .env in a single command.

Caddy is the reverse proxy that will redirect traffic to both Windmill (port 8000) and the LSP (the monaco assistant) service (port 3001) and multiplayer service (port 3002). It also redirects TCP traffic on port 25 to Windmill (port 2525) for email triggers. Postgres holds the entire state of Windmill, the rest is fully stateless, Windmill-LSP provides editor intellisense.

Make sure Docker is started:

    Mac: open /Applications/Docker.app
    Windows: start docker
    Linux: sudo systemctl start docker

and type the following commands:

curl https://raw.githubusercontent.com/windmill-labs/windmill/main/docker-compose.yml -o docker-compose.yml
curl https://raw.githubusercontent.com/windmill-labs/windmill/main/Caddyfile -o Caddyfile
curl https://raw.githubusercontent.com/windmill-labs/windmill/main/.env -o .env

docker compose up -d

Go to http://localhost et voilà. Then you can login for the first time.
Use an external database

For more production use-cases, we recommend using the Helm-chart. However, the docker-compose on a big instance is sufficient for many use-cases.

To setup an external database, you need to set DATABASE_URL in the .env file to point your external database. You should also set the number of db replicas to 0.
tip

In setups where you do not have access to the PG superuser (Azure PostgreSQL, GCP Postgresql, etc), you will need to set the initial role manually. You can do so by running the following command:

curl https://raw.githubusercontent.com/windmill-labs/windmill/main/init-db-as-superuser.sql -o init-db-as-superuser.sql
psql <DATABASE_URL> -f init-db-as-superuser.sql

Make sure that the user used in the DATABASE_URL passed to Windmill has the role windmill_admin and windmill_user:

GRANT windmill_admin TO <user used in database_url>;
GRANT windmill_user TO <user used in database_url>;

Set number of replicas accordingly in docker-compose

In the docker-compose, set the number of windmill_worker and windmill_worker_native replicas to your needs.
Enterprise Edition

To use the Enterprise Edition, you need pass the license key in the instance settings. A same license key can be used for multiple instances (for dev instances make sure to turn on the 'Non-prod instance' flag from the instance settings).

You can then set the number of replicas of the multiplayer container to 1 in the docker-compose.

You will be provided a license key when you purchase the enterprise edition or start a trial. Start a trial from the Pricing page or contact us at contact@windmill.dev to get a trial license key. You will benefit from support, SLA and all the additional features of the enterprise edition.

More details at:
Upgrade to Enterprise Edition
Docs on how to upgrade to the Enterprise Edition of a Self-Hosted Windmill instance.
Configuring domain and reverse proxy

To deploy Windmill to the windmill.example.com domain, make sure to set "Base Url" correctly in the Instance settings.

You can use any reverse proxy as long as they behave mostly like the default provided following caddy configuration:

:80 {
        bind {$ADDRESS}
        reverse_proxy /ws/* http://lsp:3001
        reverse_proxy /* http://windmill_server:8000
}

The default docker-compose file exposes the caddy reverse-proxy on port 80 above, configured by the caddyfile curled above. Configure both the caddyfile and the docker-compose file to fit your needs. The documentation for caddy is available here.
Use provided Caddy to serve https

For simplicity, we recommend using an external reverse proxy such as Cloudfront or Cloudflare and point to your instance on the port you have chosen (by default, :80).

However, Caddy also supports HTTPS natively via its tls directive. Multiple options are available. Caddy can obtain certificates automatically using the ACME protocol, a provided CA file, or even a custom HTTP endpoint. The simplest is to provide your own certifcate and key files. You can do so by mounting an additional volume containing those two files to the Caddy container and adding a tls /path/to/cert.pem /path/to/key.pem directive to the Caddy file. Make sure to expose the port :443 instead of :80 and Caddy will take care of the rest.

For all the above, see the commented lines in the caddy section of the docker-compose.
Traefik configuration
Here is a template of a docker-compose to expose Windmill to Traefik. Make sure to replace the traefik network with whatever network you have it running on. Code below:
Deployment

Once you have setup your environment for deployment, you can run the following command:

docker compose up

That's it! Head over to your domain and you should be greeted with the login screen.

In practice, you want to run the Docker containers in the background so they don't shut down when you disconnect. Do this with the --detach or -d parameter as follows:

docker compose up -d

Set up limits for workers and memory

From your docker-compose, you can set limits for consumption of workers and memory:

windmill_worker:
  image: ${WM_IMAGE}
  pull_policy: always
  deploy:
    replicas: 3
    resources:
      limits:
        cpus: "1"
        memory: 2048M

It is useful on Enterprise Edition to avoid exceeding the terms of your subscription.
Update

To update to a newer version of Windmill, all you have to do is run:

docker compose stop windmill_worker
docker compose pull windmill_server
docker compose up -d

Database volume is persistent, so updating the database image is safe too. Windmill provides graceful exit for jobs in workers so it will not interrupt current jobs unless they are longer than docker stop hard kill timeout (30 seconds).

It is sufficient to run docker compose up -d again if your Docker is already running detached, since it will pull the latest :main version and restart the containers. NOTE: The previous images are not removed automatically, you should also run docker builder prune to clear old versions.
Reset your instance

Windmill stores all of its state in PostgreSQL and it is enough to reset the database to reset the instance. Hence, in the setup above, to reset your Windmill instance, it is enough to reset the PostgreSQL volumes. Run:

docker compose down --volumes
docker volume rm -f windmill_db_data

and then:

docker compose up -d

Helm chart

We also provide a convenient Helm chart for Kubernetes-based self-hosted set-up.

Detailed instructions can be found in the README file in the official repository of the chart.
tip

If you're familiar with Helm and want to jump right in, you can deploy quickly with the snippet below.

# add the Windmill helm repo
helm repo add windmill https://windmill-labs.github.io/windmill-helm-charts/
# install chart with default values
helm install windmill-chart windmill/windmill  \
      --namespace=windmill             \
      --create-namespace

Detailed instructions in the official repository.
Enterprise deployment with Helm

The Enterprise edition of Windmill uses different base images and supports additional features.

See the Helm chart repository README for more details.

To unlock EE, set in your values.yaml:

enterprise:
	enable: true

You will want to disable the postgresql provided with the helm chart and set the database_url to your own managed postgresql.

For high-scale deployments (> 20 workers), we recommend using the global S3 cache. You will need an object storage compatible with the S3 protocol.
Run Windmill without using a Postgres superuser

Create the database with your non-super user as owner:

CREATE DATABASE windmill OWNER nonsuperuser

As a superuser, create the windmill_user and windmill_admin roles with the proper privileges, using:

curl https://raw.githubusercontent.com/windmill-labs/windmill/main/init-db-as-superuser.sql -o init-db-as-superuser.sql
psql <DATABASE_URL> -f init-db-as-superuser.sql

where init-db-as-superuser.sql is this file.

Then finally, run the following commands:

GRANT windmill_admin TO nonsuperuser;
GRANT windmill_user TO nonsuperuser;

NOTE: Make sure the roles windmill_admin and windmill_user have access to the database and the schema:

You can ensure this by running the following commands as superuser while inside the database. Replace the schema name public with your schema, in case you use a different one:

GRANT USAGE ON SCHEMA public TO windmill_admin;
GRANT USAGE ON SCHEMA public TO windmill_user;

note

If you use a schema other than public, pass PG_SCHEMA=<schema> as an environment variable to every windmill_server container.
First time login

Once you have setup your environment for deployment and have access to the instance, you will be able to login with the default credentials admin@windmill.dev / changeme (even if you setup OAuth).

First time login

Then you will be redirected to the Instance settings page. You can always change the settings later.

Instance settings

Then you can set up a new account that will override the default superadmin account. This is also where you can setup Hub Sync to use on your workspace Resource types from Windmill Hub ((by default, everyday)).

Setup account

At last, you will get to create a new workspace.

Create workspace
Self-signed certificates

Detailed guide for using Windmill with self-signed certificates here (archived version).

TL;DR: below
Mount CA certificates in Windmill

    Ensure CA certificate is base64 encoded and has .crt extension.
    Create a directory for CA certificates.
    Modify docker-compose.yml to mount this directory to /usr/local/share/ca-certificates in read-only mode.
    Use INIT_SCRIPT in the worker config to run update-ca-certificates in worker containers.

Establish Deno’s trust

Set environment variable DENO_TLS_CA_STORE=system,mozilla in docker-compose.yml for Windmill workers.
Configure Python (requests & httpx) Trust:

Set REQUESTS_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt & SSL_CERT_FILE with the same value in the worker’s environment variables.
Configure Java's Trust:

keytool -import -alias "your.corp.com" -file path/to/cert.crt -keystore path/to/created/dir/with/certs/truststore.jks -storepass '12345678' -noprompt

note

By default Windmill will use 123456 password. But you can change it to something else by setting JAVA_STOREPASS.

You can alse set JAVA_TRUST_STORE_PATH to point to different java truststore.
Running Windmill as non-root user
Certain cloud providers require containers to be run as non-root users. For these cases you can use the windmill user (uid/gid 1000) or run it as any other non-root user by passing the --user windmill argument. For the windmill helm chart, you can pass the runAsUser or runAsNonRoot in the podSecurityContext.