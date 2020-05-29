#!/usr/bin/env bash
export DEBIAN_FRONTEND=noninteractive
set -x

mkdir -p /tmp/logs
mkdir -p /etc/consul.d


# Function used for initialize Consul. Requires 2 arguments: Log level and the hostname assigned by the respective variables.
# If no log level is specified in the main.tf, then default "info" is used.
init_consul () {
    killall consul

    LOG_LEVEL=$1
    if [ -z "$1" ]; then
        LOG_LEVEL="info"
    fi

    if [ -d /tmp/logs ]; then
    mkdir /tmp/logs
    LOG="/tmp/logs/$2.log"
    else
    LOG="consul.log"
    fi

    sudo useradd --system --home /etc/consul.d --shell /bin/false consul
    sudo chown --recursive consul:consul /etc/consul.d
    sudo chmod -R 755 /etc/consul.d/
    sudo mkdir --parents /tmp/consul
    sudo chown --recursive consul:consul /tmp/consul
    mkdir -p /tmp/consul_logs/
    sudo chown --recursive consul:consul /tmp/consul_logs/

    cat << EOF > /etc/systemd/system/consul.service
    [Unit]
    Description="HashiCorp Consul - A service mesh solution"
    Documentation=https://www.consul.io/
    Requires=network-online.target
    After=network-online.target

    [Service]
    User=consul
    Group=consul
    ExecStart=/usr/local/bin/consul agent -config-dir=/etc/consul.d/
    ExecReload=/usr/local/bin/consul reload
    KillMode=process
    Restart=on-failure
    LimitNOFILE=65536


    [Install]
    WantedBy=multi-user.target

EOF
}

# Function that creates the conf file for the Consul servers. 

create_server_conf () {
    cat << EOF > /etc/consul.d/config_${DCNAME}.json
    
    {
        
        "server": true,
        "node_name": "${var2}",
        "bind_addr": "${IP}",
        "client_addr": "0.0.0.0",
        "bootstrap_expect": ${SERVER_COUNT},
        "retry_join_wan": ["provider=aws tag_key=join_wan tag_value=${JOIN_WAN}"],
        "retry_join": ["provider=aws tag_key=consul tag_value=${DCNAME}"],
        "log_level": "${LOG_LEVEL}",
        "data_dir": "/tmp/consul",
        "enable_script_checks": true,
        "domain": "${DOMAIN}",
        "datacenter": "${DCNAME}",
        "ui": true,
        "disable_remote_exec": true,
        "connect": {
          "enabled": true
        },
        "ports": {
            "grpc": 8502
        }

    }
EOF
}

# Function that creates the conf file for Consul clients. 
create_client_conf() {
    cat << EOF > /etc/consul.d/consul_client.json

        {
            "node_name": "${var2}",
            "bind_addr": "${IP}",
            "client_addr": "0.0.0.0",
            "retry_join": ["provider=aws tag_key=consul tag_value=${DCNAME}"],
            "log_level": "${LOG_LEVEL}",
            "data_dir": "/tmp/consul",
            "enable_script_checks": true,
            "domain": "${DOMAIN}",
            "datacenter": "${DCNAME}",
            "ui": true,
            "disable_remote_exec": true,
            "leave_on_terminate": false,
            "ports": {
                "grpc": 8502
            },
            "connect": {
                "enabled": true
            }
        }

EOF
}

# Starting consul
init_consul ${LOG_LEVEL} ${var2} 
case "${DCNAME}" in
    "${DCNAME}")
    if [[ "${var2}" =~ "ip-10-123-1" || "${var2}" =~ "ip-10-123-1" ]]; then
        killall consul

        create_server_conf

        sudo systemctl enable consul >/dev/null
    
        sudo systemctl start consul >/dev/null
        sleep 5
    else
        if [[ "${var2}" =~ "ip-10-123-2" || "${var2}" =~ "ip-10-123-3" ]]; then
            killall consul
            create_client_conf
            sudo systemctl enable consul >/dev/null
            sudo systemctl start consul >/dev/null
        fi
    fi
    ;;
esac

sleep 5
consul members
consul members -wan



########################################### VAULT PART #####################################

sudo setcap cap_ipc_lock=+ep /usr/local/bin/vault
sudo mkdir -p /etc/vault.d 
sudo useradd --system --home /etc/vault.d --shell /bin/false vault
sudo chown -R vault:vault /etc/vault.d/

#lets kill past instance
sudo killall vault &>/dev/null

cat << EOF > /etc/systemd/system/vault.service
[Unit]
Description="HashiCorp Vault"
Documentation=https://www.vaultproject.io
Requires=network-online.target
After=network-online.target

[Service]
User=vault
Group=vault
ExecStart=/usr/local/bin/vault server  -dev -dev-listen-address=0.0.0.0:8200
ExecReload=/bin/kill --signal HUP $MAINPID
KillMode=process
Restart=on-failure
LimitNOFILE=65536


[Install]
WantedBy=multi-user.target

EOF

#start vault
sudo systemctl enable vault
sudo systemctl start vault
journalctl -f -u vault.service > /tmp/logs/${var2}-vl.log &
sudo systemctl status vault
echo vault started
sleep 20

grep VAULT_ADDR /home/ubuntu/.bash_profile || {
  echo export VAULT_ADDR=http://127.0.0.1:8200 | sudo tee -a /home/ubuntu/.bash_profile
}

grep VAULT_TOKEN ~/.bash_profile || {
  echo export VAULT_TOKEN=$(cat /etc/vault.d/.vault-token) | sudo tee -a /home/ubuntu/.bash_profile
}

export VAULT_ADDR=http://127.0.0.1:8200
export VAULT_TOKEN=$(cat /etc/vault.d/.vault-token)

mkdir -p /home/ubuntu/policy

cat << EOF > /home/ubuntu/policy/redis-pol.hcl
path "kv/redis" {
  capabilities = [ "read" ]
}
EOF

cat << EOF > /home/ubuntu/policy/vault-user-token.hcl
path "sys/auth/approle" {
  capabilities = [ "create", "read", "update", "delete", "sudo" ]
}

# Configure the AppRole auth method
path "sys/auth/approle/*" {
  capabilities = [ "create", "read", "update", "delete" ]
}

# Create and manage roles
path "auth/approle/*" {
  capabilities = [ "create", "read", "update", "delete", "list" ]
}

# Write ACL policies
path "sys/policies/acl/*" {
  capabilities = [ "create", "read", "update", "delete", "list" ]
}

# Write test data
# Set the path to "secret/data/mysql/*" if you are running `kv-v2`
path "secret/mysql/*" {
  capabilities = [ "create", "read", "update", "delete", "list" ]
}
EOF

vault secrets enable -version=1 kv
vault kv put kv/redis pass=${pass}
vault auth enable approle
vault policy write redis /home/ubuntu/policy/redis-pol.hcl
vault policy write user_token /home/ubuntu/policy/vault-user-token.hcl 
vault token create -policy=user_token > /home/ubuntu/policy/vault.txt -field "token"
vault write auth/approle/role/redis policies="redis"
consul kv put vault/token $(cat /home/ubuntu/policy/vault.txt)


cat << EOF > /usr/local/bin/check_service.sh
#!/usr/bin/env bash

systemctl status vault | grep "active (running)"
EOF

chmod +x /usr/local/bin/check_service.sh

# Register vault in consul
var2=$(hostname)

cat << EOF > /etc/consul.d/vault.json
{
  "service": {
      "name": "vault",
      "tags": ["${var2}"],
      "port": 8200
  },
  "checks": [
      {
          "id": "vl_service_check",
          "name": "Service check",
          "args": ["/usr/local/bin/check_service.sh", "-limit", "256MB"],
          "interval": "10s",
          "timeout": "1s"
      }
  ]
}
EOF

sleep 10
consul reload
sleep 30
