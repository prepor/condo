condo [![Build Status](https://travis-ci.org/prepor/condo.svg?branch=next)](https://travis-ci.org/prepor/condo)
-------------------------------------------------------------------------------
![Condo](http://c1.staticflickr.com/5/4040/5141512500_613bde41aa_z.jpg)

Condo is a simple idempotent supervisor for Docker containers. It can be used as a basic brick to build reliable and declarative systems without complex and smart schedulers like Kubernetes, but in combination with tools like [nginx-proxy](https://github.com/jwilder/nginx-proxy), [Consul Template](https://github.com/hashicorp/consul-template), and [Registrator](https://github.com/gliderlabs/registrator).

## Features

* Watches directories and starts a Docker container for each specification inside them.
* Reacts to any changes in these directories and specifications therein (adding, removing and updating of specifications).
* Zero downtime deployments with `:After` option enabled. It starts a new container *in parallel* with the old one, and stops the old one only after the new one is successfully started (including health checks). It also contains embedded TCP proxy to have one static port in front of such containers.
* Supports the health check feature of Docker (from `1.12`). It considers a container `Stable` only when the health checks are passed.
* Exposes its state into an external storage (e.g. Consul). It can be used for monitoring of the entire system, higher level orchestration, etc.
* Provides http-endpoint to track the deployment status of a service (/v1/wait_for) locally or across cluster.
* Nice UI for exploring the state of current daemon and the entire system (if state exposing is enabled). It can use gossip protocol to inspect state of all condos without any external dependencies.
* Container specification is fully opaque for condo, it has the same format as [Docker's remote API](https://docs.docker.com/engine/reference/api/docker_remote_api_v1.24/#create-a-container), so there is no additional point of indirection and you can use all of Docker's features (even unreleased).

The main task of Condo is keep your system in sync with list of service specifications. Simple.

## Quickstart

Condo is compiled into native code, but the primary distribution method is Docker, of course.

Note: you can always see help by executing `docker run prepor/condo:0.11.dev --help`

Condo uses [edn](https://github.com/edn-format/edn) format to describe specifications. It's a human and machine readable format, with comments, and it's extendable.

Let's start nginx with condo:

    mkdir -p /tmp/condo_specs && echo '{:spec {:Image "nginx:1.11.4-alpine"} :deploy [:After 5]}' > /tmp/condo_specs/nginx.edn
    docker run -v /tmp/condo_specs:/var/lib/condo -v /var/run/docker.sock:/var/run/docker.sock -ti prepor/condo:0.11.dev

You will see `Wait` -> `Stable` log messages. It means that our container has successfully started.

Now we will try to deploy a new version of this image:

    echo '{:spec {:Image "nginx:oops-alpine"} :deploy [:After 5]}' > /tmp/condo_specs/nginx.edn
    
Oops, there is a typo and we have an error: `manifest for nginx:oops-alpine not found`. The current state now is `TryAgainNext`. Condo will try to deploy this spec until it is successful or until a new specification arrives. Note that we still have `nginx:1.11.4-alpine` running – that's because we've specified the `:deploy [:After 5]` option, and the new container tries to start in parallel with the previous one.

Let's fix the typo:

    echo '{:spec {:Image "nginx:1.11.5-alpine"} :deploy [:After 5]}' > /tmp/condo_specs/nginx.edn
    
Yep, now it's deployed, the previous container was stopped.

That's basically the core functionality of condo ;)

## Configuration

`condo start` command has number of arguments which can be inspected via `condo start --help` (`docker run prepor/condo:0.11.dev --help`). Docker connection can be configured via standard environment variables:

* `DOCKER_HOST` to set the url to the docker server.
* `DOCKER_API_VERSION` to set the version of the API to reach, leave empty for latest.
* `DOCKER_CERT_PATH` to load the TLS certificates from.
* `DOCKER_TLS_VERIFY` to enable or disable TLS verification, off by default.

If you going to use Consul as state storage it can be configured via environment variables:

* `CONSUL_HTTP_ADDR`
* `CONSUL_HTTP_TOKEN`
* `CONSUL_HTTP_AUTH` the HTTP authentication header
* `CONSUL_HTTP_SSL` whether or not to use HTTPS.
* `CONSUL_CACERT` the CA file to use for talking to Consul over TLS.
* `CONSUL_CAPATH` the path to a directory of CA certs to use for talking to Consul over TLS.
* `CONSUL_CLIENT_CERT` the client cert file to use for talking to Consul over TLS
* `CONSUL_CLIENT_KEY` the client key file to use for talking to Consul over TLS.
* `CONSUL_TLS_SERVER_NAME` the server name to use as the SNI host when connecting via TLS
* `CONSUL_HTTP_SSL_VERIFY` whether or not to disable certificate checking.

## Specification format

Condo watches for `*.edn` files in all directories defined as PREFIXes via command line interface.

It has only one required parameter: `:spec`. It contains Docker container description in the format of [Docker's remote API](https://docs.docker.com/engine/reference/api/docker_remote_api_v1.24/#create-a-container).
The only required field inside this description is `:Image`. See [example](specs/full.edn) of specification.

Optional parameters:
* `:deploy` (default `[:Before]`). Can be `[:Before]` or `[:After n]` where `n` is the number of seconds before stopping the previous container after the successful start of the new one.
* `:stop-timeout` in seconds (default 10). It will be passed into `stop` Docker operation. It describes how long it will wait before force-stopping the container.
* `:name` name of container. By default containers have names consist of name of spec file + some random suffix. In can't be used with :After deploy strategy.
* `:proxy` start TCP proxy in front of containers. Expects condo is run in the same docker network as containers. Usable only with :After deploy strategy.
* `:watch-image` condo will periodically pull image and in the case of update it redeploy container.
  
## Real world setups

There are some examples of combining condo with other tools. It proceeds
our Quickstart section.

### consul-template

https://github.com/hashicorp/consul-template

We can use Consul Template to generate specifications. One of the nicest properties of this is that we can store current version of the container inside Consul and dynamically change it for all instances.

    echo '{:spec {:Image "nginx:{{key_or_default "/versions/nginx" "1.11.5-alpine"}}"} :deploy [:After 5]}
         ' > /tmp/condo_specs/nginx.edn.ctmpl

    echo '{:spec {:Name "consul" :Image "consul:v0.7.0"
                  :Cmd ["agent" "-dev" "-client=0.0.0.0"]
                  :HostConfig {:PortBindings {"8500/tcp" [{:HostPort "8500"}]}}}}
         ' > /tmp/condo_specs/consul.edn

    echo '{:spec {:Image "prepor/consul-template:0.16.0"
                  :Cmd ["-consul" "consul:8500"
                        "-template" "/specs/nginx.edn.ctmpl:/specs/nginx.edn"]
                  :HostConfig {:Binds ["/tmp/condo_specs:/specs/"]
                               :Links ["consul:consul"]}}}
         ' > /tmp/condo_specs/consul_template.edn
         
Now we can deploy nginx via `curl`! ;)

    curl -XPUT localhost:8500/v1/kv/versions/nginx -d '1.11.4-alpine'

We can add this line, for example, to CI, and both deploy and undeploy new versions of application manually or automatically.

You can also do service discovery via ENV variables or support HA PostgreSQL with [Patroni](https://github.com/zalando/patroni).

### nginx-proxy

https://github.com/jwilder/nginx-proxy

Our nginx instances don't expose any ports into host machine, that's why we can run them in parallel while deploying. With nginx-proxy, we can expose one static port for them.

    echo '{:spec {:Image "nginx:1.11.5-alpine"
                  :Env ["VIRTUAL_HOST=nginx"]} :deploy [:After 5]}
          ' > /tmp/condo_specs/nginx.edn
          
    echo '{:spec {:Image "jwilder/nginx-proxy:0.4.0"
           :Env ["DEFAULT_HOST=nginx"]
           :HostConfig {:Binds ["/var/run/docker.sock:/tmp/docker.sock"]
                        :PortBindings {"80/tcp" [{:HostPort "8000"}]}}}}
          ' > /tmp/condo_specs/proxy.edn 
          
Now `curl localhost:8000` sends requests to currently deployed container.

### Registrator

https://github.com/gliderlabs/registrator

Docker Registrator registers containers as service in different service discovery registries, such as Consul.

    echo '{:spec {:Image "nginx:1.11.5-alpine"
                  :HostConfig {:PublishAllPorts true}} :deploy [:After 5]}
          ' > /tmp/condo_specs/nginx.edn
          
    echo '{:spec {:Image "gliderlabs/registrator:v7"
           :Cmd ["consul://localhost:8500"]
           :HostConfig {:Binds ["/var/run/docker.sock:/tmp/docker.sock"]
                        :NetworkMode "host"}}}
         ' > /tmp/condo_specs/registrator.edn 
         
It will register nginx-service which starts at a random port in Consul. Now this information can be used by some external load balancer.
 
## Best practices

* Define health checks. Without them, condo considers a container successfully started even if it crashed in a second.
* Use restart strategies. Condo stops monitoring a container after it successfully started. But Docker daemon does. You can restart containers by `:RestartPolicy` option of `HostConfig`, for example `:RestartPolicy {:Name "on-failure"}`.
  
## How it works

One of the main reasons why condo exists is because a deployment tool should be simple and understandable by all users. I am not sure if anyone really knows what Kubernetes does in each case (1,500,000 lines of code by the way!). Condo is basically a simple state machine for each service:

![Fsm](doc/fsm.png)

## Build

You will need go and godep

    godep restore
    go run main.go

Release build

    make bin docker release
    
## Credits

* Andrew Rudenko @prepor
* Aleksey Kuleshov @superkonduktr
* Roman Sokolov @little-arhat
* Galina Dautova @galinad
* Petr Yanovich @fl00r

Thanks to [Flocktory](https://github.com/flocktory/) and [HealthSamurai](https://github.com/HealthSamurai) for support of the development.
