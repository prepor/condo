package consul

import (
	"encoding/json"
	"strings"
	"time"

	log "github.com/Sirupsen/logrus"
	consul "github.com/hashicorp/consul/api"
	"github.com/prepor/condo/expose"
	"github.com/prepor/condo/instance"
)

type Self struct {
	prefix string
	client *consul.Client
	writes chan *expose.Instance
}

func New(prefix string) *Self {
	client, err := consul.NewClient(consul.DefaultConfig())
	if err != nil {
		log.WithError(err).Fatal("Invalid consul settings")
	}
	self := &Self{
		client: client,
		prefix: prefix,
		writes: make(chan *expose.Instance, 20),
	}
	go self.worker()
	return self
}

func (x *Self) SaveState(instance *expose.Instance) {
	x.writes <- instance
}

func (x *Self) ReceiveStates(done <-chan struct{}) <-chan []*expose.Instance {
	instances := make(chan []*expose.Instance)
	go func() {
		inner := make(chan consul.KVPairs, 1)
		options := &consul.QueryOptions{}
	Loop:
		for {
			go func() {
			ListLoop:
				for {
					res, meta, err := x.client.KV().List(x.prefix, options)
					if err != nil {
						select {
						case <-done:
							return
						case <-time.After(time.Second):
							continue ListLoop
						}
					}
					options.WaitIndex = meta.LastIndex
					inner <- res
					return

				}
			}()
			select {
			case <-done:
				break Loop
			case pairs := <-inner:
				res := make([]*expose.Instance, len(pairs))
				for i, v := range pairs {
					parts := strings.Split(v.Key, "/")

					var snapshot interface{}
					err := json.Unmarshal(v.Value, &snapshot)
					if err != nil {
						log.WithError(err).Error("Can't parse JSON")
						res[i] = nil
						continue
					}
					res[i] = &expose.Instance{
						Condo:    parts[len(parts)-2],
						Service:  parts[len(parts)-1],
						Snapshot: snapshot,
					}
				}
				instances <- res
			}
		}
		close(instances)
	}()
	return instances
}

func (x *Self) Stop() {
	close(x.writes)
}

type stateEntry struct {
	instance *expose.Instance
	dirty    bool
}

type writeRequest struct {
	instance *expose.Instance
	session  string
}

// Why so triky? Because we want: 1. be consistent between our state and state inside consul. 2. never blocks our main work
// So, we maintain internal state with dirty flags and constantly sync it with consul in asynchronous goroutine
func (x *Self) worker() {
	sessions := make(chan string)
	sessionClient := x.client.Session()

	state := make(map[string]*stateEntry)

	go func() {
		ttl := "10s"
		for {
			s, _, err := sessionClient.CreateNoChecks(&consul.SessionEntry{
				Name:     "condo-exposer",
				Behavior: consul.SessionBehaviorDelete,
				TTL:      ttl,
			}, nil)
			if err != nil {
				log.WithError(err).Error("Can't create session for consul exposer")
				time.Sleep(time.Second)
				continue
			}
			sessions <- s
			err = sessionClient.RenewPeriodic(ttl, s, nil, make(chan struct{}))
			if err != nil {
				log.WithError(err).Error("Can't renew session for consul exposer")
				time.Sleep(time.Second)
				continue
			}
		}
	}()

	var (
		session      string
		pending      <-chan time.Time
		actualWrites = make(chan *writeRequest, 20)
		failedWrites = make(chan *expose.Instance)
	)

	triggerPending := func() {
		p := make(chan time.Time)
		pending = p
		close(p)
	}

	go x.realWrites(failedWrites, actualWrites)

Loop:
	for {
		select {
		case i, ok := <-x.writes:
			if !ok {
				close(actualWrites)
				for {
					_, ok := <-failedWrites
					if !ok {
						break
					}
				}
				break Loop
			}
			state[i.Service] = &stateEntry{
				instance: i,
				dirty:    true,
			}
			triggerPending()
		case session = <-sessions:
			for _, v := range state {
				v.dirty = true
			}
			triggerPending()
		case <-pending:
			pending = nil
		PendingLoop:
			for k, v := range state {
				if v.dirty == false {
					continue
				}
				select {
				default:
					pending = time.After(time.Second)
					break PendingLoop
				case actualWrites <- &writeRequest{v.instance, session}:
					if _, ok := v.instance.Snapshot.(instance.Stopped); ok {
						delete(state, k)
					} else {
						v.dirty = false
					}
				}
			}
		case i := <-failedWrites:
			s, ok := state[i.Service]
			if ok {
				s.dirty = true
			} else {
				state[i.Service] = &stateEntry{
					instance: i,
					dirty:    true,
				}
			}
			pending = time.After(time.Second)
		}
	}
}

func (x *Self) realWrites(fails chan<- *expose.Instance, reqs <-chan *writeRequest) {
	kv := x.client.KV()
	for {
		req, ok := <-reqs
		if !ok {
			break
		}

		value, err := json.Marshal(req.instance.Snapshot)
		if err != nil {
			log.WithError(err).Error("Can't encode snapshot to json")
			continue
		}

		k := x.prefix + "/" + req.instance.Condo + "/" + req.instance.Service
		fail := false
		if _, ok := req.instance.Snapshot.(*instance.Stopped); ok {

			_, err = kv.Delete(k, nil)
			if err != nil {
				log.WithField("key", k).WithError(err).Error("Can't delete snapshot from consul")
			}
			fail = true
		} else {
			ok, _, err = kv.Acquire(&consul.KVPair{
				Key:     k,
				Value:   value,
				Session: req.session,
			}, nil)
			if !ok {
				log.WithField("key", k).Error("Can't put snapshot value to consul")
				fail = true
			}

			if err != nil {
				log.WithField("key", k).WithError(err).Error("Can't put snapshot value to consul")
				fail = true
			}
		}

		if fail {
			fails <- req.instance
		}
	}
}
