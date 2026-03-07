package api

import (
	"encoding/json"
	"os"
	"os/signal"
	"reflect"
	"syscall"
	"time"

	_ "github.com/lib/pq"
	nats "github.com/nats-io/nats.go"
	"github.com/sirupsen/logrus"
	"github.com/ugorji/go/codec"
	trmm "github.com/wh1te909/trmm-shared"
)

func Svc(logger *logrus.Logger, cfg string) {
	logger.Infoln("GuardianRMM NATS API starting...")
	db, r, err := GetConfig(cfg)
	if err != nil {
		logger.Fatalln("Failed to load config:", err)
	}
	defer db.Close()

	opts := []nats.Option{
		nats.Name("guardianrmm-nats-api"),
		nats.UserInfo("tacticalrmm", r.Key),
		nats.ReconnectWait(time.Second * 2),
		nats.RetryOnFailedConnect(true),
		nats.MaxReconnects(-1),
		nats.ReconnectBufSize(-1),
		nats.DisconnectErrHandler(func(nc *nats.Conn, nerr error) {
			logger.Warnln("NATS disconnected:", nerr)
		}),
		nats.ReconnectHandler(func(nc *nats.Conn) {
			logger.Infoln("NATS reconnected")
		}),
		nats.ErrorHandler(func(nc *nats.Conn, sub *nats.Subscription, nerr error) {
			logger.Errorln("NATS error:", nerr)
			if sub != nil {
				logger.Errorf("Subscription: %+v\n", sub)
			}
		}),
	}

	nc, err := nats.Connect(r.NatsURL, opts...)
	if err != nil {
		logger.Fatalln("Failed to connect to NATS:", err)
	}

	// Verify authentication succeeded
	if !nc.IsConnected() {
		logger.Fatalln("NATS connection failed - check credentials")
	}
	logger.Infoln("NATS connected successfully")

	sub, err := nc.Subscribe("*", func(msg *nats.Msg) {
		var mh codec.MsgpackHandle
		mh.MapType = reflect.TypeOf(map[string]interface{}(nil))
		mh.RawToString = true
		dec := codec.NewDecoderBytes(msg.Data, &mh)

		switch msg.Reply {
		case "agent-hello":
			go func() {
				var p trmm.CheckInNats
				if err := dec.Decode(&p); err != nil {
					logger.Warnln("Failed to decode agent-hello:", err)
					return
				}
				now := time.Now().UTC()
				logger.Debugln("Hello", p, now)
				stmt := `
				UPDATE agents_agent
				SET last_seen=$1, version=$2
				WHERE agents_agent.agent_id=$3;
				`
				_, err = db.Exec(stmt, now, p.Version, p.Agentid)
				if err != nil {
					logger.Errorln("agent-hello db error:", err)
				}
			}()

		case "agent-publicip":
			go func() {
				var p trmm.PublicIPNats
				if err := dec.Decode(&p); err != nil {
					logger.Warnln("Failed to decode agent-publicip:", err)
					return
				}
				logger.Debugln("Public IP", p)
				stmt := `
				UPDATE agents_agent SET public_ip=$1 WHERE agents_agent.agent_id=$2;`
				_, err = db.Exec(stmt, p.PublicIP, p.Agentid)
				if err != nil {
					logger.Errorln("agent-publicip db error:", err)
				}
			}()

		case "agent-agentinfo":
			go func() {
				var r trmm.AgentInfoNats
				if err := dec.Decode(&r); err != nil {
					logger.Warnln("Failed to decode agent-agentinfo:", err)
					return
				}
				stmt := `
					UPDATE agents_agent
					SET hostname=$1, operating_system=$2,
					plat=$3, total_ram=$4, boot_time=$5, needs_reboot=$6, logged_in_username=$7, goarch=$8
					WHERE agents_agent.agent_id=$9;`

				logger.Debugln("Info", r)
				_, err = db.Exec(stmt, r.Hostname, r.OS, r.Platform, r.TotalRAM, r.BootTime, r.RebootNeeded, r.Username, r.GoArch, r.Agentid)
				if err != nil {
					logger.Errorln("agent-agentinfo db error:", err)
				}

				if r.Username != "None" {
					stmt = `UPDATE agents_agent SET last_logged_in_user=$1 WHERE agents_agent.agent_id=$2;`
					logger.Debugln("Updating last logged in user:", r.Username)
					_, err = db.Exec(stmt, r.Username, r.Agentid)
					if err != nil {
						logger.Errorln("agent-agentinfo last_user db error:", err)
					}
				}
			}()

		case "agent-disks":
			go func() {
				var r trmm.WinDisksNats
				if err := dec.Decode(&r); err != nil {
					logger.Warnln("Failed to decode agent-disks:", err)
					return
				}
				logger.Debugln("Disks", r)
				b, err := json.Marshal(r.Disks)
				if err != nil {
					logger.Errorln("agent-disks marshal error:", err)
					return
				}
				stmt := `
				UPDATE agents_agent SET disks=$1 WHERE agents_agent.agent_id=$2;`
				_, err = db.Exec(stmt, b, r.Agentid)
				if err != nil {
					logger.Errorln("agent-disks db error:", err)
				}
			}()

		case "agent-winsvc":
			go func() {
				var r trmm.WinSvcNats
				if err := dec.Decode(&r); err != nil {
					logger.Warnln("Failed to decode agent-winsvc:", err)
					return
				}
				logger.Debugln("WinSvc", r)
				b, err := json.Marshal(r.WinSvcs)
				if err != nil {
					logger.Errorln("agent-winsvc marshal error:", err)
					return
				}
				stmt := `
				UPDATE agents_agent SET services=$1 WHERE agents_agent.agent_id=$2;`
				_, err = db.Exec(stmt, b, r.Agentid)
				if err != nil {
					logger.Errorln("agent-winsvc db error:", err)
				}
			}()

		case "agent-wmi":
			go func() {
				var r trmm.WinWMINats
				if err := dec.Decode(&r); err != nil {
					logger.Warnln("Failed to decode agent-wmi:", err)
					return
				}
				logger.Debugln("WMI", r)
				b, err := json.Marshal(r.WMI)
				if err != nil {
					logger.Errorln("agent-wmi marshal error:", err)
					return
				}
				stmt := `
				UPDATE agents_agent SET wmi_detail=$1 WHERE agents_agent.agent_id=$2;`
				_, err = db.Exec(stmt, b, r.Agentid)
				if err != nil {
					logger.Errorln("agent-wmi db error:", err)
				}
			}()

		default:
			logger.Debugln("Unknown message type:", msg.Reply)
		}
	})
	if err != nil {
		logger.Fatalln("Failed to subscribe:", err)
	}

	nc.Flush()

	if err := nc.LastError(); err != nil {
		logger.Fatalln("NATS error after flush:", err)
	}

	logger.Infoln("GuardianRMM NATS API ready, listening for messages...")

	// Graceful shutdown
	sigChan := make(chan os.Signal, 1)
	signal.Notify(sigChan, syscall.SIGINT, syscall.SIGTERM)
	<-sigChan

	logger.Infoln("Shutting down GuardianRMM NATS API...")
	if err := sub.Unsubscribe(); err != nil {
		logger.Warnln("Error unsubscribing:", err)
	}
	nc.Drain()
	logger.Infoln("GuardianRMM NATS API stopped.")
}
