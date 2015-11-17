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
