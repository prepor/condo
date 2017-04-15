(ns condo.subs
  (:require [re-frame.core :as re :refer [reg-sub subscribe]]
            [condo.utils :as utils]
            [clojure.string :as str]))

(reg-sub :page #(:page %))
(reg-sub :local #(:local %))
(reg-sub :global #(:global %))
(reg-sub :now #(:now %))
(reg-sub :filter #(:filter %))

(defn color [snapshot]
  (case (:State snapshot)
    ("Stable" "BothStarted") :green
    ("Init" "Wait" "WaitNext") :yellow
    ("TryAgain" "TryAgainNext") :red
    :yellow))

(defn calculate-duration [now t]
  (let [d (quot (- now t) 1000)
        secs (rem d 60)
        d (quot d 60)
        minutes (rem d 60)
        d (quot d 60)
        hours (rem d 60)
        days (quot hours 24)
        hours (rem hours 24)]
    (str (when (pos? days) (str days "d"))
         (when (pos? hours) (str hours "h"))
         (when (pos? minutes) (str minutes "m"))
         (when (pos? secs) (str secs "s")))))

(defn format-snapshot [now snap]
  (let [started-at
        (case (:State snap)
          ("Wait", "Stable") (-> snap :Container :StartedAt)
          ("WaitNext") (-> snap :Current :StartedAt)
          ("TryAgainNext") (-> snap :Current :StartedAt)
          ("BothStarted") (-> snap :Prev :StartedAt)
          nil)]
    {:color (color snap)
     :state (:State snap)
     :image (case (:State snap)
              ("Wait", "Stable") [(-> snap :Container :Spec :Image)]
              ("WaitNext") [(-> snap :Current :Spec :Image)
                            (-> snap :Next :Spec :Image)]
              ("TryAgain") [(-> snap :Spec :Image)]
              ("TryAgainNext") [(-> snap :Current :Spec :Image)
                                (-> snap :Spec :Image)]
              ("BothStarted") [(-> snap :Prev :Spec :Image)
                               (-> snap :Next :Spec :Image)]
              [])
     :container (case (:State snap)
                  ("Wait", "Stable") [(-> snap :Container :Id)]
                  ("WaitNext") [(-> snap :Current :Id)
                                (-> snap :Next :Id)]
                  ("TryAgainNext") [(-> snap :Current :Id)]
                  ("BothStarted") [(-> snap :Prev :Id)
                                   (-> snap :Next :Id)]
                  [])
     :duration (if started-at
                 (calculate-duration now (js/Date. started-at))
                 "-")}))

(defn format-service [now s]
  (assoc (format-snapshot now (:Snapshot s))
         :service (:Service s)
         :host (:Condo s)))

(defn format-local-service [now service snapshot]
  (assoc (format-snapshot now snapshot)
         :service service))

(reg-sub
 :local-services
 :<- [:local] :<- [:now]
 (fn [[local now] _]
   (->> local
        (sort-by first)
        (map #(format-local-service now (first %) (second %))))))

(reg-sub
 :entities
 :<- [:page] :<- [:global] :<- [:now] :<- [:filter]
 (fn [[page global now filter-string] _]
   (->> (case page
          :global-hosts (group-by :Condo global)
          :global-services (group-by :Service global))
        (sort-by first)
        (filter (fn [[k _]] (str/index-of k filter-string)))
        (map (fn [[label services]]
               {:label label
                :services (map (partial format-service now) services)})))))

(reg-sub
 :sidebar-entities
 :<- [:entities]
 (fn [entities]
   (for [{:keys [label services]} entities
         :let [by-color (->> services
                             (group-by :color)
                             (utils/map-vals count))]]
     [label (:green by-color) (:yellow by-color) (:red by-color)])))
