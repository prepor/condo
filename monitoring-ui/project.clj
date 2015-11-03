(defproject condo "0.1.0-SNAPSHOT"
  :dependencies [[org.clojure/clojure "1.7.0"]
                 [org.clojure/clojurescript "1.7.122"]
                 [reagent "0.5.1"]
                 [cljs-http "0.1.37"]]
  :plugins [[lein-figwheel "0.4.1"]
            [lein-cljsbuild "1.1.0"]]
  :clean-targets [:target-path "out" "resources/public/static/cljs"]
  :cljsbuild {:builds [{:id "dev"
                        :source-paths ["src"]
                        :figwheel true
                        :compiler {:main "condo.core"
                                   :asset-path "static/cljs/out"
                                   :output-to  "resources/public/static/cljs/main.js"
                                   :output-dir "resources/public/static/cljs/out"}}
                       {:id "prod"
                        :source-paths ["src"]
                        :compiler {:main "condo.core"
                                   :optimizations :advanced
                                   :asset-path "static/cljs/out"
                                   :output-to  "out/cljs/main.js"
                                   :output-dir "out/cljs/out"}}]})
