(ns condo.views
  (:require [re-frame.core :as re :refer [subscribe dispatch]]
            [re-com.core :as c]
            [goog.string :as gstring]))


(defn navigation []
  (let [page @(subscribe [:page])]
    [c/horizontal-pill-tabs
     :model page
     :tabs [{:id :global-services :label "By service"}
            {:id :global-hosts :label "By host"}
            {:id :local :label "Local"}]
     :on-change #(dispatch [:navigate %])]))

(defn details-selector []
  [c/horizontal-bar-tabs
   :model :compact
   :tabs [{:id :compact :label "Compact view"}
          {:id :verbose :label "Verbose view"}]
   :on-change #(dispatch [:view-mode %])])

(defn header []
  [c/h-box
   :justify :between
   :children [[navigation] ;; [details-selector]
              ]])

(defn filter-field []
  (let [v @(subscribe [:filter])]
    [c/input-text
     :model v
     :placeholder "Service name"
     :on-change #(dispatch [:filter %])
     :change-on-blur? false]))

(defn sidebar-item [[title green yellow red]]
  [c/hyperlink-href
   :href (str "#entity-" title)
   :class "sidebar-item"
   :label
   [c/h-box
    :align :center
    :justify :between
    :children [[c/label :label title]
               [c/h-box
                :gap "0.3em"
                :children [(when (pos? green)
                             [c/label :class "badge badge-success" :label green])
                           (when (pos? yellow)
                             [c/label :class "badge badge-warning" :label yellow])
                           (when (pos? red)
                             [c/label :class "badge badge-dangre" :label red])]]]]])

(defn entities-list []
  (let [entities @(subscribe [:sidebar-entities])]
    [c/v-box
     :gap "0.5em"
     :children (for [e entities]
                 [sidebar-item e])]))

(defn sidebar []
  [c/v-box
   :size "1"
   :gap "1em"
   :children [[filter-field]
              [entities-list]]])

(defn render-images [images]
  (case (count images)
    0 "None"
    1 (gstring/format "[%s]" (first images))
    2 (gstring/format "[%s] -> [%s]" (first images) (second images))))

(defn render-containers [containers]
  (case (count containers)
    0 "None"
    1 (gstring/format "%s" (subs (first containers) 0 12))
    2 (gstring/forfmat "%s -> %s"
                       (subs (first containers) 0 12)
                       (subs (second containers) 0 12))))

(defn content-item-service [page s]
  [:tr
   [:td [c/label :label (case page
                          (:local :global-hosts) (:service s)
                          :global-services (:host s))]]
   [:td [c/label :class (str "badge " (case (:color s)
                                        :green "badge-success"
                                        :yellow "badge-warning"
                                        :red "badge-danger"))
         :label (:state s)]]
   [:td [c/label :label (render-images (:image s))]]
   [:td [c/label :label (render-containers (:container s))]]
   [:td [c/label :label (:duration s)]]])

(defn services-table [services]
  (let [page @(subscribe [:page])]
    [:table.table.table-striped
     [:thead
      [:tr
       [:th (case page
              (:local :global-hosts) "Service"
              :global-services "Host")]
       [:th "State"]
       [:th "Image"]
       [:th "Container"]
       [:th "Running time"]]]
     [:tbody
      (for [s services] ^{:key (case page
                                 (:local :global-hosts) (:service s)
                                 :global-services (:host s))}
        [content-item-service page s])]]))

(defn content-item [label services]
  [c/border
   :padding "0.5em"
   :radius "3px"
   :attr {:id (str "entity-"label)}
   :child
   [c/v-box
    :children [[c/title
                :level :level2
                :label label]
               [services-table services]]]])

(defn content-items []
  (let [entities @(subscribe [:entities])]
    [c/v-box
     :size "4"
     :gap "1em"
     :children (for [{:keys [label services]} entities]
                 [content-item label services])]))

(defn local-services []
  (let [services @(subscribe [:local-services])]
    [c/border
     :padding "0.5em"
     :radius "3px"
     :width "100%"
     :child [c/box
             :width "100%"
             :child [services-table services]]]))

(defn content []
  [c/h-box
   :gap "2em"
   :children [[sidebar] [content-items]]])

(defn local-content []
  [c/h-box
   :gap "2em"
   :children [[local-services]]])

(defn states [page]
  [c/v-box
   :max-width "1280px"
   :style {:padding-top "10px"
           :margin-left "auto"
           :margin-right "gap"}
   :gap "2em"
   :children [[header]
              (case page
                :local [local-content]
                [content])]])

(defn message [class msg]
  [c/box
   :width "100%"
   :height "100%"
   :child
   [c/box
    :margin "auto"
    :min-width "20em"
    :class (str "alert " class)
    :child [c/title :level :level2 :label msg]]])

(defn error []
  (message "alert-danger" "Error, sorry :("))

(defn loading []
  (message "alert-info" "Loading..."))

(defn main []
  (let [page @(subscribe [:page])]
    (case page
      :loading [loading]
      (:local :global-services :global-hosts) [states page]
      :error [error])))
