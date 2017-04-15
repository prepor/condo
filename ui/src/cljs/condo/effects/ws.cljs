(ns condo.effects.ws
  (:require [re-frame.core :as re]))

(def connections (atom {}))

(defn make-connection
  [{:keys [path open-event data-event error-event close-event json?] :as spec}]
  (let [url (:url spec
                  (let [loc (.-location js/window)]
                    (str (if (= (.-protocol loc) "https:")
                           "wss://" "ws://")
                         (.-host loc) path)))
        c (js/WebSocket. url)
        id (:id spec url)]
    (when open-event
      (set! (.-onopen c) #(re/dispatch [open-event])))
    (when data-event
      (set! (.-onmessage c) #(re/dispatch [data-event
                                           (if json?
                                             (js->clj (.parse js/JSON (.-data %))
                                                      :keywordize-keys true)
                                             %)])))
    (when error-event
      (set! (.-onerror c) #(re/dispatch [error-event])))
    (when close-event
      (set! (.-onclose c) #(re/dispatch [close-event])))))

(defn handler [one-or-many]
  (let [specs (if (vector? one-or-many) one-or-many [one-or-many])]
    (doseq [spec specs]
      (make-connection spec))))

(defn stop-handler [one-or-many])

(re/reg-fx :ws handler)
(re/reg-fx :stop-ws stop-handler)
