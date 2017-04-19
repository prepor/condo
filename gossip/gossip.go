package gossip

import (
	"encoding/json"
	"fmt"
	"sync"
	"time"

	log "github.com/Sirupsen/logrus"
	"github.com/gorilla/websocket"
	"github.com/hashicorp/memberlist"
	"github.com/prepor/condo/expose"
)

type meta struct {
	Condo   string
	ApiAddr string
	ApiPort int
}

type Config struct {
	Condo         string
	Connects      []string
	BindAddr      string
	BindPort      int
	AdvertiseAddr string
	AdvertisePort int

	ApiAddr string
	ApiPort int
}

type state struct {
	*sync.Cond
	*sync.RWMutex
	dict map[string]map[string]interface{}
}

type worker struct {
	*sync.RWMutex
	clients int
	impl    *workerImpl
}

type T struct {
	meta       *meta
	memberlist *memberlist.Memberlist
	state      *state
	worker     *worker
}

func New(config *Config) *T {
	locker := new(sync.RWMutex)
	self := &T{
		meta: &meta{
			Condo:   config.Condo,
			ApiAddr: config.ApiAddr,
			ApiPort: config.ApiPort,
		},
		state: &state{
			sync.NewCond(locker.RLocker()),
			locker,
			make(map[string]map[string]interface{}),
		},
		worker: &worker{RWMutex: new(sync.RWMutex)},
	}
	c := memberlist.DefaultLocalConfig()
	c.BindAddr = config.BindAddr
	c.BindPort = config.BindPort
	c.AdvertiseAddr = config.AdvertiseAddr
	c.AdvertisePort = config.AdvertisePort
	c.Events = self
	c.Delegate = self
	c.Name = config.Condo
	list, err := memberlist.Create(c)
	if err != nil {
		panic("Failed to create memberlist: " + err.Error())
	}
	go func() {
		for {
			_, err = list.Join(config.Connects)
			if err == nil {
				return
			}
			log.WithError(err).Warn("Can't connect to cluster")
			time.Sleep(10 * time.Second)
		}

	}()
	self.memberlist = list
	return self
}

func (x *T) SaveState(instance *expose.Instance) {
}

func (x *T) sendState(ch chan []*expose.Instance) {
	size := 0
	for _, state := range x.state.dict {
		size += len(state)
	}
	instances := make([]*expose.Instance, size)
	i := 0
	for condo, state := range x.state.dict {
		for service, snapshot := range state {
			instances[i] = &expose.Instance{
				Condo:    condo,
				Service:  service,
				Snapshot: snapshot,
			}
			i++
		}
	}
	ch <- instances
}

func (x *T) newClient() {
	x.worker.Lock()
	defer x.worker.Unlock()
	if x.worker.clients == 0 {
		x.worker.impl = newWorkerImpl(x)
	}
	x.worker.clients++
}

func (x *T) removedClient() {
	x.worker.Lock()
	defer x.worker.Unlock()
	x.worker.clients--
	if x.worker.clients == 0 {
		x.worker.impl.stop()
		x.worker.impl = nil
	}
}
func (x *T) ReceiveStates(done <-chan struct{}) <-chan []*expose.Instance {
	ch := make(chan []*expose.Instance)
	wakeups := make(chan bool, 1)
	x.newClient()
	go func() {
		defer x.removedClient()
		x.state.L.Lock()
		defer x.state.L.Unlock()
		x.sendState(ch)
		for {
			go func() {
				x.state.Wait()
				wakeups <- true
			}()
			select {
			case <-wakeups:
				x.sendState(ch)
			case <-done:
				close(ch)
				return
			}
		}
	}()

	return ch
}

func (x *T) NotifyJoin(node *memberlist.Node) {
	x.worker.RLock()
	defer x.worker.RUnlock()
	if x.worker.impl != nil {
		x.worker.impl.newNode(node)
	}
}

func (x *T) NotifyLeave(node *memberlist.Node) {
	x.worker.RLock()
	defer x.worker.RUnlock()
	if x.worker.impl != nil {
		x.worker.impl.removedNode(node)
	}
}

func (x *T) NotifyUpdate(*memberlist.Node) {

}

func (x *T) NodeMeta(limit int) []byte {
	v, err := json.Marshal(x.meta)
	if err != nil {
		log.WithError(err).Warn("Can't marshal node meta")
		return []byte("{}")
	}
	return v
}

func (x *T) NotifyMsg([]byte) {

}

func (x *T) GetBroadcasts(overhead, limit int) [][]byte {
	return make([][]byte, 0)
}

func (x *T) LocalState(join bool) []byte {
	return make([]byte, 0)
}

func (x *T) MergeRemoteState(buf []byte, join bool) {

}

type workerConnection struct {
	conn *websocket.Conn
	meta *meta
	done chan struct{}
}

type workerImpl struct {
	gossip          *T
	done            chan struct{}
	connections     map[string]*workerConnection
	connectionsLock *sync.Mutex
}

func newWorkerImpl(gossip *T) *workerImpl {
	x := &workerImpl{
		gossip:          gossip,
		done:            make(chan struct{}),
		connections:     make(map[string]*workerConnection),
		connectionsLock: new(sync.Mutex),
	}
	for _, member := range gossip.memberlist.Members() {
		x.newNode(member)
	}

	go func() {
	}()
	return x
}

func (x *workerImpl) newNode(node *memberlist.Node) {
	x.connectionsLock.Lock()
	defer x.connectionsLock.Unlock()
	var (
		meta meta
	)
	err := json.Unmarshal(node.Meta, &meta)
	if err != nil {
		log.WithField("node", node.Name).
			WithField("address", node.Address()).
			WithError(err).
			Warn("Can't parse node's meta")
		return
	}
	endpointAddr := meta.ApiAddr
	if endpointAddr == "" {
		endpointAddr = node.Addr.String()
	}
	endpoint := fmt.Sprintf("ws://%s:%d/v1/state-stream", endpointAddr, meta.ApiPort)
	conn := &workerConnection{
		meta: &meta,
		done: make(chan struct{}),
	}
	x.connections[node.Address()] = conn
	go func() {
		for {
			c, _, err := websocket.DefaultDialer.Dial(endpoint, nil)
			if err == nil {
				conn.conn = c
				break
			}
			log.WithField("endpoint", endpoint).
				WithError(err).
				Warn("Can't connect")
			time.Sleep(10 * time.Second)
			select {
			default:
			case <-conn.done:
				return
			}
		}

		for {
			_, message, err := conn.conn.ReadMessage()
			if err != nil {
				log.WithField("endpoint", endpoint).
					WithError(err).
					Warn("Can't read from WS")
				x.removedNode(node)
				return
			}
			var state map[string]interface{}

			err = json.Unmarshal(message, &state)

			if err != nil {
				log.WithField("endpoint", endpoint).
					WithError(err).
					Warn("Can't parse JSON")
				continue
			}

			x.gossip.state.Lock()
			x.gossip.state.dict[meta.Condo] = state
			x.gossip.state.Unlock()
			x.gossip.state.Broadcast()
		}

	}()

}

func (x *workerImpl) removedNode(node *memberlist.Node) {
	x.gossip.state.Lock()
	defer x.gossip.state.Unlock()
	x.connectionsLock.Lock()
	defer x.connectionsLock.Unlock()

	conn, ok := x.connections[node.Address()]
	if !ok {
		return
	}
	close(conn.done)
	delete(x.gossip.state.dict, conn.meta.Condo)
	delete(x.connections, node.Address())
	x.gossip.state.Broadcast()

}

func (x *workerImpl) stop() {
	x.connectionsLock.Lock()
	defer x.connectionsLock.Unlock()

	for _, conn := range x.connections {
		close(conn.done)
	}
}
