package api

import (
	"encoding/json"
	"fmt"
	"net/http"

	log "github.com/Sirupsen/logrus"
	"github.com/davecgh/go-spew/spew"
	negronilogrus "github.com/meatballhat/negroni-logrus"
	"github.com/prepor/condo/supervisor"
	"github.com/prepor/condo/system"
	"github.com/urfave/negroni"
)

type API struct {
	supervisor   *supervisor.Supervisor
	stateManager *stateManager
}

func New(system *system.System, supervisor *supervisor.Supervisor, address string) *API {

	api := &API{
		supervisor:   supervisor,
		stateManager: newStateManager(supervisor),
	}

	go api.worker(system, address)
	return api
}

func rootHandler(w http.ResponseWriter, r *http.Request) {
	fmt.Fprintf(w, "Welcome condo")
}

func (x *API) stateHandler(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	current := x.stateManager.readCurrent()
	spew.Dump(current)
	if err := json.NewEncoder(w).Encode(current); err != nil {
		log.WithError(err).Error("JSON encoding error in stateHandler")
	}
}

func (x *API) worker(system *system.System, address string) error {
	log.WithField("address", address).Info("Starting HTTP")
	mux := http.NewServeMux()
	mux.HandleFunc("/", rootHandler)
	mux.HandleFunc("/v1/state", x.stateHandler)

	n := negroni.New(negroni.NewRecovery())
	n.Use(negronilogrus.NewMiddleware())
	n.UseHandler(mux)

	err := http.ListenAndServe(address, n)
	if err != nil {
		log.Error(err)
		system.Stop()
		log.Fatal("HTTP server failed")
	}
	return nil
}
