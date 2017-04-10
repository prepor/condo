package api

import (
	"encoding/json"
	"fmt"
	"net/http"

	log "github.com/Sirupsen/logrus"
	"github.com/gorilla/websocket"
	negronilogrus "github.com/meatballhat/negroni-logrus"
	"github.com/prepor/condo/expose"
	"github.com/prepor/condo/supervisor"
	"github.com/prepor/condo/system"
	"github.com/urfave/negroni"
)

type API struct {
	supervisor   *supervisor.Supervisor
	stateManager *stateManager
	exposer      expose.Exposer
}

func New(system *system.System, supervisor *supervisor.Supervisor, address string) *API {

	api := &API{
		supervisor:   supervisor,
		stateManager: newStateManager(supervisor),
	}

	go api.worker(system, address)
	return api
}

func (x *API) SetExposer(exposer expose.Exposer) {
	x.exposer = exposer
}

func rootHandler(w http.ResponseWriter, r *http.Request) {
	fmt.Fprintf(w, "Welcome condo")
}

func (x *API) stateHandler(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	current := x.stateManager.readCurrent()
	if err := json.NewEncoder(w).Encode(current); err != nil {
		log.WithError(err).Error("JSON encoding error in stateHandler")
	}
}

func (x *API) checkExposer(w http.ResponseWriter) bool {
	if x.exposer == nil {
		w.WriteHeader(http.StatusNotImplemented)
		fmt.Fprintln(w, "Exposer isn't configured")
		return false
	}
	return true
}

func (x *API) globalStateHandler(w http.ResponseWriter, r *http.Request) {
	if !x.checkExposer(w) {
		return
	}
	w.Header().Set("Content-Type", "application/json")
	done := make(chan struct{})
	current := <-x.exposer.ReceiveStates(done)
	close(done)
	if err := json.NewEncoder(w).Encode(current); err != nil {
		log.WithError(err).Error("JSON encoding error in globalStateHandler")
	}
}

func (x *API) globalStateStreamHandler(w http.ResponseWriter, r *http.Request) {
	conn, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		log.WithError(err).Error("Can't upgrade websocket connection")
		return
	}
	done := make(chan struct{})
	states := x.exposer.ReceiveStates(done)
	go func() {
		if _, _, err := conn.NextReader(); err != nil {
			close(done)
		}
	}()
	for {
		res, ok := <-states
		if !ok {
			conn.Close()
			return
		}

		if err := conn.WriteJSON(res); err != nil {
			close(done)
		}
	}

}

var upgrader = websocket.Upgrader{
	ReadBufferSize:  1024,
	WriteBufferSize: 1024,
}

func (x *API) stateStreamHandler(w http.ResponseWriter, r *http.Request) {
	conn, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		log.WithError(err).Error("Can't upgrade websocket connection")
		return
	}
	done := make(chan struct{})
	updates := x.stateManager.readStream(done)
	go func() {
		if _, _, err := conn.NextReader(); err != nil {
			close(done)
		}
	}()
	for {
		update, ok := <-updates
		if !ok {
			conn.Close()
			return
		}

		if err := conn.WriteJSON(update); err != nil {
			close(done)
		}
	}
}

func (x *API) worker(system *system.System, address string) error {
	log.WithField("address", address).Info("Starting HTTP")
	mux := http.NewServeMux()
	mux.HandleFunc("/", rootHandler)
	mux.HandleFunc("/v1/state", x.stateHandler)
	mux.HandleFunc("/v1/state-stream", x.stateStreamHandler)

	mux.HandleFunc("/v1/global-state", x.globalStateHandler)
	mux.HandleFunc("/v1/global-state-stream", x.globalStateStreamHandler)

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
