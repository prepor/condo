package top

import (
	"fmt"
	"sort"
	"sync"
	"time"

	"github.com/Jeffail/gabs"
	log "github.com/Sirupsen/logrus"
	"github.com/gorilla/websocket"
	"github.com/jroimartin/gocui"
)

var (
	selectedService string
	cursor          = -1
	states          map[string]*gabs.Container
	lock            sync.Mutex
)

func cursorDown(g *gocui.Gui, v *gocui.View) error {
	lock.Lock()
	defer lock.Unlock()

	if cursor < len(states)-1 {
		cursor++
	}
	g.Execute(layout)
	return nil
}

func selectService(g *gocui.Gui, v *gocui.View) error {
	lock.Lock()
	defer lock.Unlock()

	if cursor < 0 {
		return nil
	}

	sorted := sortServices()
	if cursor > len(sorted) {
		return nil
	}
	selectedService = sorted[cursor]
	g.Execute(layout)
	return nil
}

func cancelSelected(g *gocui.Gui, v *gocui.View) error {
	selectedService = ""
	g.Execute(layout)
	return nil
}

func cursorUp(g *gocui.Gui, v *gocui.View) error {
	lock.Lock()
	defer lock.Unlock()

	if cursor != 0 {
		cursor--
	}
	g.Execute(layout)
	return nil
}

func sortServices() []string {
	keys := make([]string, 0, len(states))
	for k := range states {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}

func selectedLayout(g *gocui.Gui) {
	maxX, maxY := g.Size()

	s, exists := states[selectedService]

	if !exists {
		selectedService = ""
		g.Execute(layout)
		return
	}

	v, err := g.SetView("main", 0, 0, maxX-1, maxY-1)
	if err != nil && err != gocui.ErrUnknownView {
		log.Panicln(err)
	}
	v.Title = selectedService
	v.Clear()

	CliDetails(v, s)

	v, err = g.SetView("menu", 0, maxY-3, maxX-1, maxY-1)
	if err != nil && err != gocui.ErrUnknownView {
		log.Panicln(err)
	}
	v.Frame = false
	v.Clear()
	fmt.Fprintf(v, "\033[38;7mQ\033[0m List\n")
}

func listLayout(g *gocui.Gui) {
	maxX, maxY := g.Size()

	v, err := g.SetView("main", 0, 0, maxX-1, maxY-1)
	if err != nil && err != gocui.ErrUnknownView {
		log.Panicln(err)
	}
	v.Title = "Condo services"
	v.Clear()

	i := 0
	sortedServices := sortServices()
	for _, service := range sortedServices {
		s := states[service]
		if i == cursor {
			fmt.Fprintf(v, "\033[38;4m%s\033[0m", service)
			for i = 0; i < 20-len(service); i++ {
				fmt.Fprint(v, " ")
			}

		} else {
			fmt.Fprintf(v, "%-20s", service)
		}
		CliStatus(v, s)
		fmt.Fprint(v, "\n")
		i++
	}

	v, err = g.SetView("menu", 0, maxY-3, maxX-1, maxY-1)
	if err != nil && err != gocui.ErrUnknownView {
		log.Panicln(err)
	}
	v.Frame = false
	v.Clear()
	fmt.Fprintf(v, "\033[38;7mEnter\033[0m Details \033[38;7m↑↓\033[0m Select\n")
}

func layout(g *gocui.Gui) error {
	lock.Lock()
	defer lock.Unlock()
	if selectedService != "" {
		selectedLayout(g)
	} else {
		listLayout(g)
	}
	return nil
}

func Go(address string) {
	g, err := gocui.NewGui(gocui.Output256)

	states = make(map[string]*gabs.Container)

	// now := time.Now()

	// states = map[string]instance.Snapshot{
	// 	"nginx": &instance.Init{},
	// 	"postgres": &instance.Wait{
	// 		Container: &docker.Container{
	// 			Id:        "9e3250d03a54f3355f0563998b73bd396756cac6dd590e397aa3bfd25f97d850",
	// 			StartedAt: &now,
	// 			Spec: &spec.Spec{
	// 				Spec: map[interface{}]interface{}{
	// 					edn.Keyword("Image"): "nginx:postgres",
	// 				},
	// 			},
	// 		},
	// 	},
	// 	"nginx2": &instance.Stable{
	// 		Container: &docker.Container{
	// 			Id:        "9e3250d03a54f3355f0563998b73bd396756cac6dd590e397aa3bfd25f97d850",
	// 			StartedAt: &now,
	// 			Spec: &spec.Spec{
	// 				Spec: map[interface{}]interface{}{
	// 					edn.Keyword("Image"): "nginx:2",
	// 				},
	// 			},
	// 		},
	// 	},
	// 	"nginx3": &instance.TryAgain{
	// 		Spec: &spec.Spec{
	// 			Spec: map[interface{}]interface{}{
	// 				edn.Keyword("Image"): "nginx:3",
	// 			},
	// 		},
	// 	},
	// 	"narus": &instance.BothStarted{
	// 		Prev: &docker.Container{
	// 			Id:        "9e3250d03a54f3355f0563998b73bd396756cac6dd590e397aa3bfd25f97d850",
	// 			StartedAt: &now,
	// 			Spec: &spec.Spec{
	// 				Spec: map[interface{}]interface{}{
	// 					edn.Keyword("Image"): "narus:1",
	// 				},
	// 			},
	// 		},
	// 		Next: &docker.Container{
	// 			Id:        "9e3250d03a54f3355f0563998b73bd396756cac6dd590e397aa3bfd25f97d850",
	// 			StartedAt: &now,
	// 			Spec: &spec.Spec{
	// 				Spec: map[interface{}]interface{}{
	// 					edn.Keyword("Image"): "narus:2",
	// 				},
	// 			},
	// 		},
	// 	},
	// }

	if err != nil {
		log.Panicln(err)
	}
	defer g.Close()

	c, _, err := websocket.DefaultDialer.Dial(address, nil)
	if err != nil {
		log.WithError(err).Fatal("Can't connect to", address)
	}
	defer c.Close()

	go func() {
		for {
			var message interface{}
			err := c.ReadJSON(&message)
			if err != nil {
				log.WithError(err).Fatal("Can't parse JSON message")
			}
			lock.Lock()
			// spew.Config.DisableMethods = true

			// spew.Dump(message)
			c, err := gabs.Consume(message)
			if err != nil {
				log.Fatal(err)
			}
			name := c.Path("Name").Data().(string)
			if c.Path("Snapshot.State").Data().(string) == "Stopped" {
				delete(states, name)
			} else {
				states[name] = c.Path("Snapshot")
			}
			lock.Unlock()
			g.Execute(layout)
		}
	}()

	g.SetManagerFunc(layout)

	go func() {
		for {
			time.Sleep(time.Second)
			lock.Lock()
			if selectedService != "" {
				g.Execute(layout)
			}
			lock.Unlock()
		}
	}()

	if err := g.SetKeybinding("", gocui.KeyCtrlC, gocui.ModNone, quit); err != nil {
		log.Panicln(err)
	}

	if err := g.SetKeybinding("", gocui.KeyArrowDown, gocui.ModNone, cursorDown); err != nil {
		log.Panicln(err)
	}
	if err := g.SetKeybinding("", gocui.KeyArrowUp, gocui.ModNone, cursorUp); err != nil {
		log.Panicln(err)
	}

	if err := g.SetKeybinding("", 'q', gocui.ModNone, cancelSelected); err != nil {
		log.Panicln(err)
	}

	if err := g.SetKeybinding("", gocui.KeyEnter, gocui.ModNone, selectService); err != nil {
		log.Panicln(err)
	}

	if err := g.MainLoop(); err != nil && err != gocui.ErrQuit {
		log.Panicln(err)
	}
}

func quit(g *gocui.Gui, v *gocui.View) error {
	return gocui.ErrQuit
}
