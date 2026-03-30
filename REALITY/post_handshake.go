package reality

import (
	"encoding/binary"
	"io"
	"time"
)

func postHandshakeProfileKey(dest string, hello *clientHelloMsg) string {
	if hello == nil {
		return dest + "  0"
	}

	key := dest + " " + hello.serverName
	if len(hello.alpnProtocols) == 0 {
		return key + " 0"
	}
	if hello.alpnProtocols[0] == "h2" {
		return key + " 2"
	}
	return key + " 1"
}

func randomUint32(r io.Reader) (uint32, error) {
	var buf [4]byte
	if _, err := io.ReadFull(r, buf[:]); err != nil {
		return 0, err
	}
	return binary.LittleEndian.Uint32(buf[:]), nil
}

func randomIntRange(r io.Reader, min, max int) (int, error) {
	if max <= min {
		return min, nil
	}
	v, err := randomUint32(r)
	if err != nil {
		return 0, err
	}
	return min + int(v%uint32(max-min+1)), nil
}

func randomDurationRange(r io.Reader, min, max time.Duration) (time.Duration, error) {
	if max <= min {
		return min, nil
	}
	v, err := randomUint32(r)
	if err != nil {
		return 0, err
	}
	delta := max - min
	return min + time.Duration(v%uint32(delta+1)), nil
}

func randomizedTicketCount(r io.Reader, observed int) (int, error) {
	max := 2
	if observed >= 2 {
		max = 3
	}
	return randomIntRange(r, 1, max)
}

func randomizedTicketExtra(r io.Reader) ([][]byte, error) {
	size, err := randomIntRange(r, 0, 96)
	if err != nil {
		return nil, err
	}
	if size == 0 {
		return nil, nil
	}
	extra := make([]byte, 4+size)
	extra[0] = 'r'
	extra[1] = 't'
	extra[2] = 'y'
	extra[3] = 1
	if _, err := io.ReadFull(r, extra[4:]); err != nil {
		return nil, err
	}
	return [][]byte{extra}, nil
}

func (hs *serverHandshakeStateTLS13) startRandomizedPostHandshakeTickets(dest string) {
	if hs == nil || hs.c == nil || hs.clientHello == nil || !hs.shouldSendSessionTickets() || hs.c.resumptionSecret == nil {
		return
	}

	key := postHandshakeProfileKey(dest, hs.clientHello)
	observed := 0
	if val, ok := GlobalPostHandshakeRecordsLens.Load(key); ok {
		if lens, ok := val.([]int); ok {
			observed = len(lens)
		}
	}

	scheduler := hs.c.initPostHandshakeTicketScheduler()

	go func(c *Conn, scheduler *postHandshakeTicketScheduler) {
		r := c.config.rand()

		fallbackDelay, err := randomDurationRange(r, 450*time.Millisecond, 2500*time.Millisecond)
		if err != nil {
			fallbackDelay = time.Second
		}

		var initialDelay time.Duration
		select {
		case <-scheduler.stop:
			return
		case <-scheduler.appData:
			initialDelay, err = randomDurationRange(r, 60*time.Millisecond, 320*time.Millisecond)
			if err != nil {
				initialDelay = 120 * time.Millisecond
			}
		case <-time.After(fallbackDelay):
			initialDelay, err = randomDurationRange(r, 120*time.Millisecond, 600*time.Millisecond)
			if err != nil {
				initialDelay = 250 * time.Millisecond
			}
		}

		if initialDelay > 0 {
			select {
			case <-scheduler.stop:
				return
			case <-time.After(initialDelay):
			}
		}

		count, err := randomizedTicketCount(r, observed)
		if err != nil {
			count = 1
		}

		for i := 0; i < count; i++ {
			extra, err := randomizedTicketExtra(r)
			if err != nil {
				return
			}
			select {
			case <-scheduler.stop:
				return
			default:
			}
			if err := c.sendSessionTicket(false, extra); err != nil {
				return
			}
			if i+1 >= count {
				return
			}
			delay, err := randomDurationRange(r, 90*time.Millisecond, 650*time.Millisecond)
			if err == nil && delay > 0 {
				select {
				case <-scheduler.stop:
					return
				case <-time.After(delay):
				}
			}
		}
	}(hs.c, scheduler)
}
