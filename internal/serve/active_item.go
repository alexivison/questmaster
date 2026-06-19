//go:build linux || darwin

package serve

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"sync"
	"time"
)

// ActiveItem is the transient viewer payload relayed by qm serve.
type ActiveItem struct {
	ID      string `json:"id,omitempty"`
	Type    string `json:"type"`
	Title   string `json:"title,omitempty"`
	QuestID string `json:"quest_id,omitempty"`
	Path    string `json:"path,omitempty"`
	URL     string `json:"url,omitempty"`
	HTML    string `json:"html,omitempty"`
}

func PublishActiveItem(ctx context.Context, socketPath string, item ActiveItem) error {
	if socketPath == "" {
		socketPath = DefaultSocketPath()
	}
	raw, err := json.Marshal(item)
	if err != nil {
		return fmt.Errorf("marshal active item: %w", err)
	}
	dialer := net.Dialer{Timeout: 200 * time.Millisecond}
	conn, err := dialer.DialContext(ctx, "unix", socketPath)
	if err != nil {
		return err
	}
	defer conn.Close() //nolint:errcheck

	enc := json.NewEncoder(conn)
	dec := json.NewDecoder(conn)
	if err := enc.Encode(Request{
		ID:     json.RawMessage(`"active-item"`),
		Method: methodPublishActiveItem,
		Data:   raw,
	}); err != nil {
		return fmt.Errorf("send active item: %w", err)
	}
	var env Envelope
	if err := dec.Decode(&env); err != nil {
		return fmt.Errorf("read active item response: %w", err)
	}
	if env.OK == nil || !*env.OK {
		if env.Error == "" {
			env.Error = "publish active item failed"
		}
		return errors.New(env.Error)
	}
	return nil
}

func PublishActiveItemBestEffort(ctx context.Context, socketPath string, item ActiveItem) {
	ctx, cancel := context.WithTimeout(ctx, 250*time.Millisecond)
	defer cancel()
	_ = PublishActiveItem(ctx, socketPath, item)
}

type activeItemBroker struct {
	mu          sync.Mutex
	subscribers map[chan ActiveItem]struct{}
}

func newActiveItemBroker() *activeItemBroker {
	return &activeItemBroker{subscribers: map[chan ActiveItem]struct{}{}}
}

func (b *activeItemBroker) Subscribe(ctx context.Context, enabled bool) (<-chan ActiveItem, func()) {
	if !enabled {
		return nil, func() {}
	}
	ch := make(chan ActiveItem, 16)
	var once sync.Once
	unsubscribe := func() {
		once.Do(func() {
			b.mu.Lock()
			delete(b.subscribers, ch)
			close(ch)
			b.mu.Unlock()
		})
	}

	b.mu.Lock()
	b.subscribers[ch] = struct{}{}
	b.mu.Unlock()

	go func() {
		<-ctx.Done()
		unsubscribe()
	}()
	return ch, unsubscribe
}

func (b *activeItemBroker) Publish(item ActiveItem) {
	b.mu.Lock()
	defer b.mu.Unlock()
	for ch := range b.subscribers {
		select {
		case ch <- item:
		default:
			select {
			case <-ch:
			default:
			}
			select {
			case ch <- item:
			default:
			}
		}
	}
}

func activeItemFromRequest(req Request) (ActiveItem, error) {
	if len(req.Data) == 0 {
		return ActiveItem{}, fmt.Errorf("active item data is required")
	}
	var item ActiveItem
	if err := json.Unmarshal(req.Data, &item); err != nil {
		return ActiveItem{}, fmt.Errorf("parse active item: %w", err)
	}
	if item.Type == "" {
		return ActiveItem{}, fmt.Errorf("active item type is required")
	}
	return item, nil
}

func subscribesActiveItem(req Request) bool {
	for _, topic := range req.Topics {
		switch topic {
		case topicActiveItem, "item", "view":
			return true
		}
	}
	return false
}
