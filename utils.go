package main

import "strings"

func NormalizeEndpoint(endpoint string, schema string) string {
	if !(strings.HasPrefix(endpoint, "http://") ||
		strings.HasPrefix(endpoint, "https://") ||
		strings.HasPrefix(endpoint, "/")) {
		endpoint = schema + "://" + endpoint
	} else if strings.HasPrefix(endpoint, "tcp://") {
		endpoint = strings.Replace(endpoint, "tcp", schema, 1)
	}
	return endpoint
}
