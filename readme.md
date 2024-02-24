# Ghost Playbook by Tegar Imansyah

Ghost is a blogging platform that really focus on blogging and publishing. It's not a general purpose CMS like wordpress or strapi. We can use ghost as fullstack bloging platform or headless CMS.

In this repo, I will share how I usually deploy and configure a ghost with docker. It's not simply run `docker run ghost` but we will add some configuration and maybe create a custom image.

## Our Goals

- Run a docker image is cheap (or free), but managed database is not.
- SQLite is the most affordable (since it doesn't need any server). But Ghost 5 are [dropping it's support for SQLite](https://ghost.org/changelog/5) in production. But yeah we can still use it.
- When we run container, most of the time we will expect the storage is ephemeral. So you lost your data (especially our SQLite db) once you delete the container. So we need to Backup it (use external volume or other approach).
- I use litestream to replicate the sqlite db and save it to S3 compatible object storage (I use Cloudflare R2). The cost is super cheap (or free) and the data is save. I also can take a look my data without go to my server.
- Since we know we will deal with ephemeral container, it's nice to setup remote storage for our media, e.g. in S3.

To achive that goals, we need to check current ghost docker image and look how we can improve it.

## TLDR

Use my docker image in dockerhub and use it's configuration.

## What We Have Inside Ghost Official Image?

Let's get the latest ghost image and go to inside the image using sh

```sh
docker pull ghost:alpine
docker run --rm -it ghost bash
```

> [!NOTE] 
> Anyway, ghost has 2 flavors, debian and alpine. Like in the other image, alpine typically has less image size but we may face difficulties in installing some dependencies or build tools. You also can't simply reuse script that build for debian/ubuntu. We can learn about how docker build the ghost image from this repo [https://github.com/docker-library/ghost](https://github.com/docker-library/ghost).

Before we explore inside the image, we can see in the Dockerfile which file is used to run

```dockerfile
...
COPY docker-entrypoint.sh /usr/local/bin
ENTRYPOINT ["docker-entrypoint.sh"]

CMD ["node", "current/index.js"]
```

Let's explore what we have inside the image

```sh
# First of all, let's see about who and where we are. ps aux to check what is the PID 1.
$ whoami
root
$ pwd
/var/lib/ghost
$ ps aux
PID   USER     TIME  COMMAND
    1 root      0:00 bash
   20 root      0:00 ps aux

# Let's see the structure of the ghost, I use tree to easily explore the folder and file
$ apk add tree
$ tree -L 2 .
.
├── config.development.json -> config.production.json
├── config.production.json
├── content
├── content.orig
│   ├── apps
│   ├── data
│   ├── files
│   ├── images
│   ├── logs
│   ├── media
│   ├── public
│   ├── settings
│   └── themes
├── current -> /var/lib/ghost/versions/5.79.1
└── versions
    └── 5.79.1

# Let's see the default configuration
$ cat config.production.json 
{
  "url": "http://localhost:2368",
  "server": {
    "port": 2368,
    "host": "::"
  },
  "mail": {
    "transport": "Direct"
  },
  "logging": {
    "transports": [
      "file",
      "stdout"
    ]
  },
  "process": "systemd",
  "paths": {
    "contentPath": "/var/lib/ghost/content"
  }
}

# Remember the important file in dockerfile? Yes, index.js and docker-entrypoint.sh
$ cat current/index.js 
// Load New Relic
if (process.env.PRO_ENV) {
    require('newrelic');
}

require('./ghost');

$ cat /usr/local/bin/docker-entrypoint.sh 
#!/bin/bash
set -e

# allow the container to be started with `--user`
if [[ "$*" == node*current/index.js* ]] && [ "$(id -u)" = '0' ]; then
        find "$GHOST_CONTENT" \! -user node -exec chown node '{}' +
        exec su-exec node "$BASH_SOURCE" "$@"
fi

if [[ "$*" == node*current/index.js* ]]; then
        baseDir="$GHOST_INSTALL/content.orig"
        for src in "$baseDir"/*/ "$baseDir"/themes/*; do
                src="${src%/}"
                target="$GHOST_CONTENT/${src#$baseDir/}"
                mkdir -p "$(dirname "$target")"
                if [ ! -e "$target" ]; then
                        tar -cC "$(dirname "$src")" "$(basename "$src")" | tar -xC "$(dirname "$target")"
                fi
        done
fi

exec "$@"
```

Here is my take:

- By default, it run as root. Since it based on node image, I think we can use `node` user. Fortunately there is a function if we switch user in the `docker-entrypoint.sh`.
- We can add configuration in environment variable (good in serverless env) or directly to `config.production.json` file (good in kubernetes/docker swarm via secret). The default content is very minimal.
- In `current/index.js`, we can see there is `PRO_ENV`. It looks like the ghost pro is also using this image and it will enable telemetry to new relic.
- In `docker-entrypoint.sh`, if we run `node [wildcard to catch all flag] current/index.js`, additional step is executed. The first one if we run as specific user, then the content ownership is transfered to that user. The second one is to check whether the `content` folder is already available, if not then it will copy from `content.orig`

## Add Litestream in Alpine image

Litestream is available in it's [github repo release](https://github.com/benbjohnson/litestream/releases). We can simply download and extract it to `/usr/local/bin`. Since we will work with sqlite, we need to install sqlite too

```dockerfile
FROM ghost:alpine

# Add streamlite
ADD https://github.com/benbjohnson/litestream/releases/download/v0.3.13/litestream-v0.3.13-linux-arm6.tar.gz /usr/local/bin
RUN tar -xvf /usr/local/bin/litestream-v0.3.13-linux-arm6.tar.gz -C /usr/local/bin && \
    rm /usr/local/bin/litestream-v0.3.13-linux-arm6.tar.gz && \
    apk add --no-cache sqlite

# Add streamlite config
COPY ./litestream.yml ./litestream.yml
CMD ["litestream", "replicate", "-config", "litestream.yml", "-exec", "'node current/index.js'"]
```

In the last 2 lines of the new dockerfile, we can see we add litestream config and how we change the way we run the container. We will talk about config in the next chapter and focus on CMD for now. 

Please remember that our entrypoint is `ENTRYPOINT ["docker-entrypoint.sh"]` and the previous cmd is `CMD ["node", "current/index.js"]`. Our complete command to run the container will be:

```bash
$ docker-entrypoint.sh node current/index.js
```

Since the last line of that entrypoint script is `exec "$@"`, so it will replace the current process (docker entrypoint) with whatever the argument. We call it `replace` because it will have PID 1, and we need it to signal handling.

Since we need not only node process but also litestream process, and the best practice of container is only have single process, then we need to slightly modified the CMD. Fortunately, litestream has the flag `-exec` to execute the next command as a child process.

```diff
- CMD ["node", "current/index.js"]
+ CMD ["litestream", "replicate", "-config", "litestream.yml", "-exec", "'node current/index.js'"]
```

## Add S3 Storage Adapter

I use this https://github.com/colinmeinke/ghost-storage-adapter-s3/tree/master#aws-configuration, but its last commit is several years ago. Even though the code is still working, hopefully it will be available built-in ghost.

Using [this](https://github.com/colinmeinke/ghost-storage-adapter-s3/issues/100) as reference, we can add our Dockerfile with this command

```dockerfile
ENV storage__active s3
RUN npm install --prefix /tmp/ghost-storage-adapter-s3 ghost-storage-adapter-s3 && \
    cp -r /tmp/ghost-storage-adapter-s3/node_modules/ghost-storage-adapter-s3 current/core/server/adapters/storage/s3 && \
    rm -r /tmp/ghost-storage-adapter-s3

RUN npm install ghost-storage-base && npm install aws-sdk
```

By default, it will set the storage to use s3, but we still need the configuration such as key id, secret and bucket.

## Configuration

There are 2 configuration that we need: Ghost and Litestream. Both of them support file and env variable.

Ghost already list of default value in [their github repo](https://github.com/TryGhost/Ghost/blob/main/ghost/core/core/shared/config/defaults.json) in json format. The documentation is [defined here](https://ghost.org/docs/config/). I convert the configuration as a env variable format [in this file](.env.example) so you can easily use in docker compose / kubernetes.

Additionally, I also add configuration for S3 storage adapter [from here](https://github.com/colinmeinke/ghost-storage-adapter-s3?tab=readme-ov-file#via-environment-variables)

Litestream config is [defined here](https://litestream.io/reference/config/) and simpler than ghost since it only took small number of config. I also have the example [in this file](./litestream.yml) that included in my Dockerfile. Unlike ghost, we can expand the variable inside the configuration (e.g. $AWS_ACCESS_KEY_ID will be expand as it's id).

So here is how I usually create the configuration:

Ghost

```bash
url="" # Your website domain

database__client="sqlite3"
database__connection__filename="content/data/ghost.db"
database__useNullAsDefault=true
database__debug=false

# I use gmail smtp, but you can use oher provider
mail__transport="SMTP"
mail__options__host="YOUR-EMAIL-SERVER-NAME"
mail__options__port=465
mail__options__service="EMAIL"
mail__options__auth__user="YOUR-EMAIL-SMTP-ACCESS-KEY-ID"
mail__options__auth__pass="YOUR-EMAIL-SMTP-SECRET-ACCESS-KEY"
mail__from="'Acme Support' <support@example.com>"

# I use Cloudflare R2 instead of AWS S3
AWS_ACCESS_KEY_ID=""
AWS_SECRET_ACCESS_KEY=""
AWS_DEFAULT_REGION=""
GHOST_STORAGE_ADAPTER_S3_PATH_BUCKET=""
GHOST_STORAGE_ADAPTER_S3_PATH_PREFIX="" # folder name inside the bucket
GHOST_STORAGE_ADAPTER_S3_ENDPOINT="https://YOUR-R2-ID.r2.cloudflarestorage.com" # S3-compatible endpoint
GHOST_STORAGE_ADAPTER_S3_FORCE_PATH_STYLE="true"
```

Litestream

```bash
access-key-id: $AWS_ACCESS_KEY_ID
secret-access-key: $AWS_SECRET_ACCESS_KEY

dbs:
  - path: ${database__connection__filename} # local path to the SQLite database
    replicas:
      - type: s3
        # region: us-west-1 # Only for blackblaze and S3. Compare it in https://bongkar.cloud/object-storage-comparison/
        bucket: ${GHOST_STORAGE_ADAPTER_S3_PATH_BUCKET}
        path: ${GHOST_STORAGE_ADAPTER_S3_PATH_PREFIX} # folder name inside the bucket
        endpoint: ${GHOST_STORAGE_ADAPTER_S3_ENDPOINT} # S3-compatible endpoint
        force-path-style: true
```

As you can see, Litestream config file will expand from ghost env variable.