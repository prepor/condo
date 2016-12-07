v0.10.2
--------------------------

BUGXIES:
  * Attempt to fix memory issue
  * External json format fixed
  * Static files http serving & ui-prefix setting


v0.10.1
--------------------------

BUGXIES:
  * TryAgainNext fixed

v0.10.0
--------------------------

Next revision of condo

v0.9.3
------

FEATURES:
  * condo/watcher-string tag in specs

v0.9.2
------

FEATURES:
  * Reloadable (by HUP signal) docker auth config (thanks to @little-arhat)
  * TCP health checker

BUILD:
  * Updated dependencies

v0.9.1
-----

BUGFIXES
  
  * Monitoring now works with condo 0.9.0

v0.9.0
------

FEATURES

  * Specs in edn instead of json
  * Watchers in specs
  * Multiple and prefix endpoints. condo instance now can deploy multiple specs
  * Now you can pass envs via cmdline on start. They will be merged to every spec on deploy
  
BUILD:
  
  * Got rid of oasis. Just plain ocamlbuild and makefile
  * Dependencies described via opam switch file

v0.8.0
------

FEATURES:

  * UI rework (thanks to @superkonduktr)
  * Added possibility to disabling discoveries watching (thanks to @superkonduktr) #7
  * Added file as source for spec #9
  * Added possibility to mount devices as volume #6

IMPROVEMENTS:

  * Added validation for host_port option (thanks to @superkonduktr) #8
  * GC tuning

v0.7.2
-----

FEATURES:

  * Added support for private repositories. You can pass --docker-auth argument with
    path to file in the same format as ~/.docker/config.json. Auth credentials
    from this file will be used in pull-image requests

BUG FIXES:

  * Fixed infinity waiting on 304 http responses (e.g. docker stop response)
  * Fixed incorrect handling of pulling errors
  * Fixed file descriptor leak in Consul.deregister_service

v0.7.1
------

BUG FIXES:

  * Discover for only passing services
  * File descriptors leak in http requests fixed
  * Stop previous container only after timeout with `stop-after` strategy
  * Do not crash on unexpected events (they actually possible)
  * Key names of `volume` part of spec fixed
  * Show --consul option only once in command line help

IMPROVEMENTS:

  * Much more time for shutdown (it can be forcibly killed by supervisor)
