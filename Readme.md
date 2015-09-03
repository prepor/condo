
# Condo
![Condo](http://c1.staticflickr.com/5/4040/5141512500_613bde41aa_z.jpg)

Condo -- short for condominium and also CONsul2DOcker -- is the new home for your application.

Think of it as [envconsul](https://github.com/hashicorp/envconsul) on steroids: Condo can listen [Consul](http://consul.io)
key for description of your application, spin up new containers and stop old without downtime, register Consul services, setup health checks.

# Usage

`DOCKER=http://127.0.0.1:2375 CONSUL_AGENT=http://127.0.0.1:8500 ./condo /services/hello-world`

This will start Condo listening for `/services/hello-world` key in Consul agent, available at `http://127.0.0.1:8500` and using Docker at `http://127.0.0.1:2375`.
When there is spec available under specified key, Condo will pull image, create and start containers, register Consul service and appropriate health checks. Upon
spec modification Condo will spin up new container, check service availability and then tear down the old one. Zero downtime deploys with only `curl -X PUT ...`!

# Service specification

Services specification is JSON file. See `examples` dir for examples of specs with comments.

# Build

`make` to build Condo for current OS and architecture, `make linux` to crosscompile it for Linux amd64.

# License

MIT.

# Notes

[Image source](https://www.flickr.com/photos/eager/5141512500).
