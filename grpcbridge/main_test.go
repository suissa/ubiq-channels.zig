package main

import (
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"testing"

	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/types/known/structpb"
)

func TestPublishForwardsEventToHTTPBackend(t *testing.T) {
	backend := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost { t.Errorf("method = %s", r.Method) }
		if got := r.Header.Get("X-Event-Id"); got != "evt-1" { t.Errorf("event id = %q", got) }
		if got := r.Header.Get("X-Event-Topic"); got != "orders.created" { t.Errorf("topic = %q", got) }
		if got := r.Header.Get("Content-Type"); got != "application/json" { t.Errorf("content type = %q", got) }
		body, _ := io.ReadAll(r.Body)
		if string(body) != "{\"order\":42}" { t.Errorf("body = %q", body) }
		w.WriteHeader(http.StatusAccepted)
		_, _ = w.Write([]byte(`{"accepted":true,"subscribers":1}`))
	}))
	defer backend.Close()

	request, err := structpb.NewStruct(map[string]any{
		"id": "evt-1",
		"topic": "orders.created",
		"content_type": "application/json",
		"payload": "{\"order\":42}",
	})
	if err != nil { t.Fatal(err) }
	service := &channelService{publishURL: backend.URL, client: backend.Client()}
	response, err := service.publish(context.Background(), request)
	if err != nil { t.Fatal(err) }
	if response.GetFields()["accepted"].GetBoolValue() != true {
		t.Fatalf("accepted = %v", response.GetFields()["accepted"])
	}
}

func TestPublishRejectsMissingRequiredFields(t *testing.T) {
	request, err := structpb.NewStruct(map[string]any{"topic": "orders.created"})
	if err != nil { t.Fatal(err) }
	service := &channelService{publishURL: "http://127.0.0.1:1", client: http.DefaultClient}
	_, err = service.publish(context.Background(), request)
	if status.Code(err) != codes.InvalidArgument {
		t.Fatalf("status = %v, want InvalidArgument", status.Code(err))
	}
}
