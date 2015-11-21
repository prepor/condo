## 0.7.2

FEATURES:

  * Support of private repositories. You can pass --docker-auth argument with
    path to file in the smae format as ~/.docker/config.json. Auth credentials
    from this file will be used in pull-image requests

BUG FIXES:

  * 304 http responses (in docker stop command for example) could lead to
    infinity waiting
  * Pulling error checker fixed
  * File descriptors leak in service deregistering fixed

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
