(ns condo.core
  (:require-macros [cljs.core.async.macros :refer [go go-loop]])
  (:require [reagent.core :as r]
            [cljs-http.client :as http]
            [cljs.core.async :as a :refer [<!]]
            [goog.date.relative :as relative-date]))

(enable-console-print!)

(defonce state (r/atom {:state :loading
                        :snapshot []}))

(defn deploy
  [deploy class]
  [:span
   [:span.label {:class class} (get-in deploy [:image :tag])]
   [:small.text-muted " " (relative-date/format (* (int (:created_at deploy)) 1000))]])

(defn instance-state
  [state]
  (case (first state)
    "Init" [:span.label.label-default "Initializing"]
    "Waiting" (let [[_ d] state] (deploy d "label-warning"))
    "WaitingNext" (let [[_ current next] state]
                    [:div
                     (deploy current "label-success")
                     [:br]
                     (deploy next "label-warning")])
    "Started" (let [[_ d] state] (deploy d "label-success"))
    "Stopped" [:span.label.label-default "Stopped"]))

(defn instance
  [instance]
  ^{:key (:id instance)}
  [:div.card.card-block {:style {:width "30rem" :margin-right "1rem"}}
   [:h5.card-title (:node instance)]
   [:p.card-text (instance-state (:state instance))]])

(defn group
  [group]
  ^{:key (:label group)}
  [:div
   [:h4 (:label group)]
   [:div {:style {:display "flex" :flex-wrap "wrap"}}
    (map instance (:instances group))]])

(defn snapshot
  [snapshot]
  [:div (map group snapshot)])

(defn loading
  []
  [:div.alert.alert-info {:role "alert"}
   "Loading data"])

(defn error
  []
  [:div.alert.alert-danger {:role "alert"}
   "Error while receiving data"])

(defn ui []
  (let [s @state]
    [:div
     (case (:state s)
       :loading (loading)
       :error (error)
       nil)
     (snapshot (:snapshot s))]))

(defn render []
  (r/render-component [ui] (.getElementById js/document "main")))

(defn instance-group
  [instance]
  (let [state (:state instance)]
    (case (first state)
      "Init" "Initializing"
      "Waiting" (let [[_ d] state] (get-in d [:image :name]))
      "WaitingNext" (let [[_ current next] state] (get-in current [:image :name]))
      "Started" (let [[_ d] state] (get-in d [:image :name]))
      "Stopped" "Stopping")))

(defn with-group
  [instance]
  (assoc instance :group (instance-group instance)))

(defn as-group
  [[g instances]]
  {:label g
   :instances (map #(dissoc % :group) instances)})

(defn start-receiver
  []
  (go-loop []
    (let [response (<! (http/get "/v1/snapshot"))]
      (if (= 200 (:status response))
        (let [data (->> (:body response)
                        (vals)
                        (map with-group)
                        (group-by :group)
                        (map as-group))]
          (swap! state assoc
                 :state :ok
                 :snapshot data))
        (swap! state assoc :state :error))
      (<! (a/timeout 3000))
      (recur))))

(defonce receiver (start-receiver))

(render)
