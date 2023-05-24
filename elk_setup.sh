#!/usr/bin/env bash

set -x

ver=7.0.0
rm -rf $ver
mkdir $ver
cd $ver
wget https://artifacts.elastic.co/downloads/kibana/kibana-$ver-x86_64.rpm || wget https://artifacts.elastic.co/downloads/kibana/kibana-$ver.rpm
wget https://artifacts.elastic.co/downloads/elasticsearch/elasticsearch-$ver-x86_64.rpm || wget https://artifacts.elastic.co/downloads/elasticsearch/elasticsearch-$ver.rpm
wget https://artifacts.elastic.co/downloads/logstash/logstash-$ver-x86_64.rpm || wget https://artifacts.elastic.co/downloads/logstash/logstash-$ver.rpm
wget https://packages.elastic.co/curator/5/centos/7/Packages/elasticsearch-curator-5.8.1-1.x86_64.rpm

yum -y install java-11-openjdk-devel nginx httpd-tools

yum -y install *.rpm

/usr/share/logstash/bin/logstash-plugin install logstash-codec-netflow
/usr/share/logstash/bin/logstash-plugin install logstash-codec-sflow
/usr/share/logstash/bin/logstash-plugin install logstash-filter-translate
/usr/share/logstash/bin/logstash-plugin install logstash-input-udp
/usr/share/logstash/bin/logstash-plugin install logstash-input-tcp

cat <<EOF | sudo tee /etc/logstash/conf.d/netflow.conf
input {
     udp {
       port => 9996
       type => "netflow"
       codec => netflow {
         versions => [5,9,10]
       }
     }
}

output {
 if [type] == "netflow" {
  elasticsearch {
     hosts => localhost
     index => "netflow-%{[host]}-%{+YYYY.MM.dd-HH}"
     }
   }
}
EOF

sed -i 's/^#server.hos.*/server.host: "0.0.0.0"/g' /etc/kibana/kibana.yml

cat <<EOF | sudo tee /etc/systemd/system/logstash.service
[Unit]
Description=logstash

[Service]
Type=simple
User=logstash
Group=logstash
EnvironmentFile=-/etc/default/logstash
EnvironmentFile=-/etc/sysconfig/logstash
ExecStart=/usr/share/logstash/bin/logstash "--path.settings" "/etc/logstash"
Restart=always
WorkingDirectory=/
Nice=19
LimitNOFILE=16384

[Install]
WantedBy=multi-user.target
EOF

mkdir -p /etc/nginx/conf.d/

read -e -p "Enter the login for kibana: " kibana_login
sudo htpasswd -c /etc/nginx/htpasswd.elk $kibana_login


cat <<EOF | sudo tee /etc/nginx/conf.d/kibana.conf
server {
    listen 80;
    server_name _;

    location / {
        auth_basic "Restricted Access";
        auth_basic_user_file /etc/nginx/htpasswd.elk;
        proxy_pass http://localhost:5601;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_cache_bypass \$http_upgrade;
    }
}
#API
server {
    listen 9201;
    server_name _;

    location / {
        auth_basic "Restricted Access";
        auth_basic_user_file /etc/nginx/htpasswd.elk;
        proxy_pass http://localhost:9200;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_cache_bypass \$http_upgrade;
    }
}
EOF

systemctl enable --now elasticsearch logstash kibana nginx firewalld

mkdir /etc/curator
cat <<EOF | sudo tee /etc/curator/config.yml
client:
  hosts:
    - 127.0.0.1
  port: 9200
  url_prefix:
  use_ssl: False
  certificate:
  client_cert:
  client_key:
  ssl_no_validate: False
  http_auth:
  timeout: 30
  master_only: False

logging:
  loglevel: INFO
  logfile:
  logformat: default
  blacklist: ['elasticsearch', 'urllib3']

EOF

cat <<EOF | sudo tee /etc/curator/action.yml
actions:
  1:
    action: delete_indices
    description: >-
       delete old indexes
     options:
       ignore_empty_list: True
       delete_aliases: False
       disable_action: False
     filters:
      - filtertype: pattern
        kind: prefix
        value: netflow-
      - filtertype: age
        source: creation_date
        direction: older
        unit: days
        unit_count: 7

EOF

echo '5 * * * * /usr/bin/curator --config /etc/curator/config.yml /etc/curator/action.yml' >> /etc/crontab

/bin/firewall-cmd --zone=public --add-service=http --permanent
/bin/firewall-cmd --zone=public --add-port=9201/tcp --permanent
/bin/firewall-cmd --zone=public --remove-port=5601/tcp --permanent
/bin/firewall-cmd --zone=public --remove-port=9200/tcp --permanent
/bin/firewall-cmd --reload

set +x
