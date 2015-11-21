## 0.7.2

FEATURES:

  * Added support for private repositories. You can pass --docker-auth argument with
    path to file in the same format as ~/.docker/config.json. Auth credentials
    from this file will be used in pull-image requests

BUG FIXES:

  * Fixed infinity waiting on 304 http responses (e.g. docker stop response)
  * Fixed incorrect handling of pulling errors
  * Fixed file descriptor leak in Consul.deregister_service

## 0.7.1

BUG FIXES:

  * Discover for only passing services
  * File descriptors leak in http requests fixed
  * Stop previous container only after timeout with `stop-after` strategy
  * Do not crash on unexpected events (they actually possible)
  * Key names of `volume` part of spec fixed
  * Show --consul option only once in command line help

IMPROVEMENTS:

  * Much more time for shutdown (it can be forcibly killed by supervisor)
