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
  (when deploy
    [:span
     [:span.label {:class class} (get-in deploy [:image :tag])]
     [:small.text-muted " " (relative-date/format (* (int (:created_at deploy)) 1000))]]))

(defn instance
  [instance]
  ^{:key (:id instance)}
  [:div.card.card-block {:style {:width "30rem" :margin-right "1rem"}}
   [:h5.card-title (:node instance)]
   [:p.card-text
    (deploy (get-in instance [:state :current]) "label-success")
    [:br]
    (deploy (get-in instance [:state :next]) "label-warning")]])

(defn group
  [group]
  ^{:key (get-in group [:group :name])}
  [:div
   [:h4 (get-in group [:group :name])]
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

(defn with-group
  [instance]
  (assoc instance :group {:name (or (get-in instance [:state :current :image :name])
                                    (get-in instance [:state :next :image :name]))}))

(defn as-group
  [[g instances]]
  {:group g
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
