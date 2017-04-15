(ns condo.db)

(defn default-db [now]
  {:page :loading
   :now now
   :filter ""})
