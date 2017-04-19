package api

import (
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"time"

	"github.com/Jeffail/gabs"
	log "github.com/Sirupsen/logrus"
	"github.com/gorilla/websocket"
	negronilogrus "github.com/meatballhat/negroni-logrus"
	"github.com/prepor/condo/expose"
	"github.com/prepor/condo/instance"
	"github.com/prepor/condo/static"
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
	if !x.checkExposer(w) {
		return
	}
	conn, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		log.WithError(err).Error("Can't upgrade websocket connection")
		return
	}
	done := make(chan struct{})
	states := x.exposer.ReceiveStates(done)
	go func() {
		for {
			if _, _, err := conn.NextReader(); err != nil {
				close(done)
				return
			}
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

type waitForItem struct {
	service string
	image   string
	state   string
}

func localDeployedImage(snap instance.Snapshot) string {
	switch s := snap.(type) {
	default:
		return ""
	case *instance.Stable:
		return s.Container.Spec.Image()
	case *instance.WaitNext:
		return s.Current.Spec.Image()
	case *instance.Wait, *instance.TryAgain:
		return ""
	case *instance.TryAgainNext:
		return s.Current.Spec.Image()
	case *instance.BothStarted:
		return s.Next.Spec.Image()
	}
}

func globalDeployedImage(snap interface{}) string {
	s, err := gabs.Consume(snap)
	if err != nil {
		panic(err)
	}
	state := s.Path("State").Data().(string)
	switch state {
	default:
		return ""
	case "Stable":
		return s.Path("Container.Spec.Image").Data().(string)
	case "WaitNext", "TryAgainNext":
		return s.Path("Current.Spec.Image").Data().(string)
	case "Wait", "TryAgain":
		return ""
	case "BothStarted":
		return s.Path("Next.Spec.Image").Data().(string)
	}
}

func (x *API) waitForLocal(service string, image string, done <-chan struct{}, deployed chan<- struct{}) {
	states := x.stateManager.readStream(done)
	for {
		state, ok := <-states
		if !ok {
			break
		}
		status := true
		for k, v := range state {
			if k == service {
				if localDeployedImage(v) != image {
					status = false
					break
				}
			}
		}
		if status {
			close(deployed)
			break
		}
	}

}

func (x *API) waitForGlobal(service string, image string, done <-chan struct{}, deployed chan<- struct{}) {
	states := x.exposer.ReceiveStates(done)
	for {
		state, ok := <-states
		if !ok {
			break
		}
		status := true
		for _, v := range state {
			if v.Service == service {
				if globalDeployedImage(v.Snapshot) != image {
					status = false
					break
				}
			}
		}
		if status {
			close(deployed)
			break
		}
	}

}

func (x *API) waitFor(w http.ResponseWriter, r *http.Request) {
	query := r.URL.Query()
	scope := query.Get("scope")
	service := query.Get("service")
	image := query.Get("image")

	if scope == "global" && !x.checkExposer(w) {
		return
	}

	timeoutStr := query.Get("timeout")

	if timeoutStr == "" {
		timeoutStr = "1m"
	}

	timeoutV, err := time.ParseDuration(timeoutStr)

	if err != nil {
		w.WriteHeader(http.StatusBadRequest)
		fmt.Fprintln(w, "Can't parse timeout")
		return
	}

	timeout := time.After(timeoutV)

	done := make(chan struct{})
	defer close(done)
	deployed := make(chan struct{})
	switch scope {
	case "local":
		go x.waitForLocal(service, image, done, deployed)
	case "global":
		go x.waitForGlobal(service, image, done, deployed)
	default:
		w.WriteHeader(http.StatusBadRequest)
		fmt.Fprintln(w, "Unknown scope")
		return

	}

	select {
	case <-timeout:
		w.WriteHeader(http.StatusGatewayTimeout)
		fmt.Fprintln(w, "Can't wait for desired state")
	case <-deployed:
		w.Header().Set("Content-Type", "application/json")
		fmt.Fprintln(w, "{}")
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

	mux.HandleFunc("/v1/wait-for", x.waitFor)

	if os.Getenv("LIVE_UI") == "" {
		mux.Handle("/ui/", http.StripPrefix("/ui/", http.FileServer(static.HTTP)))
	} else {
		mux.Handle("/ui/", http.StripPrefix("/ui/", http.FileServer(http.Dir("ui/resources/public"))))
	}

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
