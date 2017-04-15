(ns condo.events
  (:require [re-frame.core :as re]
            [condo.db :as db]
            condo.effects.ws))

(re/reg-cofx
 :now
 (fn [coeffects _]
   (assoc coeffects :now (js.Date.))))


(re/reg-event-db
 :navigate
 (fn [db [_ x]]
   (assoc db :page x)))

(re/reg-event-db
 :filter
 (fn [db [_ x]]
   (assoc db :filter x)))

(re/reg-event-db
 :set-local
 (fn [db [_ data]]
   (assoc db :local data)))

(re/reg-event-db
 :set-global
 (fn [db [_ data]]
   (let [page (if (= :loading (:page db))
                :global-services (:page db))]
     (assoc db
            :global data
            :page page))))

(re/reg-event-db
 :global-error
 (fn [db [_]]
   (assoc db
          :page :local
          :local-only true)))

(re/reg-event-db
 :ws-error
 (fn [db [_]]
   (assoc db :page :error)))

(re/reg-event-fx
 :timer
 [(re/inject-cofx :now)]
 (fn [{:keys [now db]} _]
   {:db (assoc db :now now)
    :dispatch-later [{:ms 1000 :dispatch [:timer]}]}))

(re/reg-event-fx
 :initialize-db
 [(re/inject-cofx :now)]
 (fn [{:keys [now]} _]
   {:db (db/default-db now)
    :ws [{:path "/v1/global-state-stream"
          :data-event :set-global
          :error-event :global-error
          :json? true}
         {:path "/v1/state-stream"
          :data-event :set-local
          :error-event :ws-error
          :json? true}]
    :dispatch-later [{:ms 1000 :dispatch [:timer]}]}))
