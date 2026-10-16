// Command grpcbridge exposes a standard gRPC API and forwards Publish calls
// to the existing Zig HTTP/1.1 channel server.
package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"strings"
	"time"

	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/health"
	healthpb "google.golang.org/grpc/health/grpc_health_v1"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/types/known/structpb"
)

const serviceName = "ubiq.channels.v1.ChannelService"

type channelService struct {
	publishURL string
	client     *http.Client
}

func (s *channelService) publish(ctx context.Context, request *structpb.Struct) (*structpb.Struct, error) {
	fields := request.GetFields()
	stringField := func(name string, required bool) (string, error) {
		value := fields[name]
		if value == nil {
			if required {
				return "", status.Errorf(codes.InvalidArgument, "missing field %q", name)
			}
			return "", nil
		}
		if value.GetKind() == nil {
			return "", status.Errorf(codes.InvalidArgument, "field %q must be a string", name)
		}
		textValue, ok := value.GetKind().(*structpb.Value_StringValue)
		if !ok {
			return "", status.Errorf(codes.InvalidArgument, "field %q must be a string", name)
		}
		return textValue.StringValue, nil
	}

	id, err := stringField("id", true)
	if err != nil { return nil, err }
	topic, err := stringField("topic", true)
	if err != nil { return nil, err }
	payload, err := stringField("payload", true)
	if err != nil { return nil, err }
	contentType, err := stringField("content_type", false)
	if err != nil { return nil, err }
	if strings.TrimSpace(id) == "" || strings.TrimSpace(topic) == "" {
		return nil, status.Error(codes.InvalidArgument, "id and topic must not be empty")
	}
	if contentType == "" { contentType = "application/json" }

	httpRequest, err := http.NewRequestWithContext(ctx, http.MethodPost, s.publishURL, bytes.NewBufferString(payload))
	if err != nil { return nil, status.Errorf(codes.Internal, "build publish request: %v", err) }
	httpRequest.Header.Set("X-Event-Id", id)
	httpRequest.Header.Set("X-Event-Topic", topic)
	httpRequest.Header.Set("Content-Type", contentType)

	response, err := s.client.Do(httpRequest)
	if err != nil { return nil, status.Errorf(codes.Unavailable, "channel backend unavailable: %v", err) }
	defer response.Body.Close()
	if response.StatusCode != http.StatusAccepted {
		return nil, status.Errorf(codes.FailedPrecondition, "channel backend returned HTTP %d", response.StatusCode)
	}
	var backendResult struct {
		Accepted bool `json:"accepted"`
		Subscribers int `json:"subscribers"`
	}
	if err := json.NewDecoder(response.Body).Decode(&backendResult); err != nil {
		return nil, status.Errorf(codes.Internal, "decode channel backend response: %v", err)
	}
	return structpb.NewStruct(map[string]any{
		"accepted": backendResult.Accepted,
		"subscribers": float64(backendResult.Subscribers),
		"backend_status": float64(response.StatusCode),
	})
}

func (s *channelService) register(server *grpc.Server) {
	server.RegisterService(&grpc.ServiceDesc{
		ServiceName: serviceName,
		HandlerType: (*interface{})(nil),
		Methods: []grpc.MethodDesc{{
			MethodName: "Publish",
			Handler: func(service any, ctx context.Context, decode func(any) error, interceptor grpc.UnaryServerInterceptor) (any, error) {
				request := new(structpb.Struct)
				if err := decode(request); err != nil { return nil, err }
				invoke := func(ctx context.Context, request any) (any, error) {
					return service.(*channelService).publish(ctx, request.(*structpb.Struct))
				}
				if interceptor == nil { return invoke(ctx, request) }
				info := &grpc.UnaryServerInfo{Server: service, FullMethod: "/" + serviceName + "/Publish"}
				return interceptor(ctx, request, info, invoke)
			},
		}},
		Metadata: "proto/channel.proto",
	}, s)
}

func main() {
	address := env("UBIQ_GRPC_ADDR", "127.0.0.1:9090")
	publishURL := env("UBIQ_HTTP_BACKEND", "http://127.0.0.1:8080/publish")
	listener, err := net.Listen("tcp", address)
	if err != nil { log.Fatalf("listen gRPC on %s: %v", address, err) }

	server := grpc.NewServer()
	bridge := &channelService{
		publishURL: publishURL,
		client: &http.Client{Timeout: 10 * time.Second},
	}
	bridge.register(server)
	healthServer := health.NewServer()
	healthServer.SetServingStatus("", healthpb.HealthCheckResponse_SERVING)
	healthServer.SetServingStatus(serviceName, healthpb.HealthCheckResponse_SERVING)
	healthpb.RegisterHealthServer(server, healthServer)

	log.Printf("gRPC listening on %s; channel backend %s", address, publishURL)
	if err := server.Serve(listener); err != nil { log.Fatal(fmt.Errorf("serve gRPC: %w", err)) }
}

func env(key, fallback string) string {
	if value := strings.TrimSpace(os.Getenv(key)); value != "" { return value }
	return fallback
}
