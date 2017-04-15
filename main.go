//go:generate fileb0x api/static.yaml

package main

import "github.com/prepor/condo/cli"

func main() {
	cli.Go()
}
