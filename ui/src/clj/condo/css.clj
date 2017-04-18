(ns condo.css
  (:require [garden.def :refer [defstyles]]))

(defstyles screen
  [:#app {:height "100%"}]
  [:.badge-warning {:background-color "#f0ad4e"}]
  [:.badge-danger {:background-color "#d9534f"}]
  [:.badge-success {:background-color "#5cb85c"}]
  [:.sidebar-item
   [:&:hover {:background-color "#f9f9f9"
              :text-decoration "none"}]])