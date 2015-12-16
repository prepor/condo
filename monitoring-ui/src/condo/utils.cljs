(ns condo.utils
  (:require [goog.date :as date]
            [goog.date.relative :as relative-date])
  (:import [goog.date UtcDateTime]))

(defn timestamp->human
  [ts]
  (let [millis (* 1000 (int ts))]
    (or (not-empty (relative-date/format millis))
        (relative-date/formatDay (UtcDateTime.fromTimestamp millis)))))

(defn timestamp-with-human
  [ts]
  (str ts " (" (timestamp->human ts) ")"))

(defn seconds-since-ts
  [ts]
  (let [now-ts (-> (date/DateTime.) (.getTime) (/ 1000))]
    (int (- now-ts ts))))
