package top

import (
	"fmt"
	"sync"

	log "github.com/Sirupsen/logrus"
	"github.com/gorilla/websocket"
	"github.com/jroimartin/gocui"
	"github.com/prepor/condo/api"
	"github.com/prepor/condo/instance"
)

func Go(address string) {
	g, err := gocui.NewGui(gocui.OutputNormal)

	states := make(map[string]instance.Snapshot)
	lock := sync.Mutex{}

	if err != nil {
		log.Panicln(err)
	}
	defer g.Close()

	c, _, err := websocket.DefaultDialer.Dial(address, nil)
	if err != nil {
		log.WithError(err).Fatal("Can't connect to", address)
	}
	defer c.Close()

	layout := func(g *gocui.Gui) error {
		lock.Lock()
		defer lock.Unlock()
		maxX, maxY := g.Size()

		v, err := g.SetView("list", 0, 0, maxX, maxY)
		if err != nil && err != gocui.ErrUnknownView {
			return err
		}
		v.Clear()
		for n, s := range states {
			fmt.Fprintf(v, "%s (%s)\n", n, s.String())
		}
		return nil
	}

	go func() {
		for {
			var message api.StreamAnswer
			err := c.ReadJSON(&message)
			if err != nil {
				log.WithError(err).Fatal("Can't parse JSON message")
			}
			lock.Lock()
			if _, ok := message.Snapshot.(*instance.Stopped); ok {
				delete(states, message.Name)
			} else {
				states[message.Name] = message.Snapshot
			}
			lock.Unlock()
			g.Execute(layout)
		}
	}()

	g.SetManagerFunc(layout)

	if err := g.SetKeybinding("", gocui.KeyCtrlC, gocui.ModNone, quit); err != nil {
		log.Panicln(err)
	}

	if err := g.MainLoop(); err != nil && err != gocui.ErrQuit {
		log.Panicln(err)
	}
}

func quit(g *gocui.Gui, v *gocui.View) error {
	return gocui.ErrQuit
}
