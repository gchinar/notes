
1) Check how the app is running on the host

Find Java process and startup command

ps -ef | grep java
ps -ef | grep -i app
ps -ef | grep -i jar

Better formatted Java process list

pgrep -a java

Show full command line for Java process

PID=$(pgrep -f 'java.*jar' | head -1)
echo "$PID"
tr '\0' ' ' < /proc/$PID/cmdline ; echo


⸻

2) Check environment variables of the running process

sudo strings /proc/$PID/environ | sort

Filter likely useful ones:

sudo strings /proc/$PID/environ | sort | egrep 'SPRING|DB_|DATABASE|JDBC|REDIS|MYSQL|POSTGRES|ORACLE|MONGO|KAFKA|RABBIT|AWS_|S3_|SECRET|TOKEN|USER|PASS|PROFILE|PORT|HOST|URL'


⸻

3) Check systemd service if app is started by systemd

List candidate services:

systemctl list-units --type=service | grep -Ei 'app|java|batch|service'
systemctl list-unit-files --type=service | grep -Ei 'app|java|batch|service'

Show service definition:

systemctl cat <SERVICE_NAME>
systemctl show <SERVICE_NAME> -p Environment
systemctl show <SERVICE_NAME> -p EnvironmentFiles
systemctl show <SERVICE_NAME> -p ExecStart

If there is an EnvironmentFile, inspect it:

sudo cat /path/from/environmentfile


⸻

4) Check common config locations on the host

sudo find /etc /opt /app /srv /home -maxdepth 4 \( -name "application.properties" -o -name "application.yml" -o -name "application.yaml" -o -name "bootstrap.properties" -o -name "bootstrap.yml" -o -name "*.conf" -o -name "*.env" \) 2>/dev/null

Check app directories:

ls -la
find . -maxdepth 3 -type f | egrep 'application|bootstrap|properties|yaml|yml|env|conf'


⸻

5) Check logs for datasource / profile / port clues

If using systemd:

journalctl -u <SERVICE_NAME> -n 200 --no-pager
journalctl -u <SERVICE_NAME> --since "1 day ago" --no-pager | egrep -i 'profile|port|datasource|jdbc|mysql|postgres|oracle|redshift|redis|kafka|started|exception|error'

If app log files exist:

find /var/log /opt /app /srv -maxdepth 4 -type f | egrep 'log$|out$'
grep -RinE 'profile|port|datasource|jdbc|mysql|postgres|oracle|redshift|redis|kafka' /var/log /opt /app /srv 2>/dev/null | head -200


⸻

6) Check what port the app listens on

sudo ss -ltnp | grep java
sudo netstat -ltnp 2>/dev/null | grep java


⸻

7) Check the repo for config keys and secret usage

From repo root:

Find Spring config files

find . -type f \( -name "application.properties" -o -name "application.yml" -o -name "application.yaml" -o -name "bootstrap.properties" -o -name "bootstrap.yml" \)

Search likely DB and secret keys

grep -RinE 'spring\.datasource|jdbc:|username|password|dbhost|dbHost|db_name|dbname|database|redshift|mysql|postgres|oracle|redis|mongo|kafka|rabbit|secret|token|api[-_]?key|aws\.' .

Search env placeholder style

grep -RinE '\$\{[^}]+\}' .

Search Spring profile usage

grep -RinE 'spring\.profiles|SPRING_PROFILES_ACTIVE|@Profile' .

Search port config

grep -RinE 'server\.port|management\.server\.port|containerPort|targetPort' .


⸻

8) Check build files for packaging/config clues

grep -RinE 'bootJar|spring-boot|application|mainClass|profiles|jib|docker' build.gradle settings.gradle gradle.properties . 2>/dev/null


⸻

9) Check whether app reads secrets from files instead of env vars

grep -RinE 'secretKeyRef|valueFrom|/etc/secrets|/var/run/secrets|aws-secrets|secretsmanager|parameterstore|ssm' .

On host:

find /etc /opt /app /srv -maxdepth 4 -type f | egrep 'secret|cred|credential|jks|p12|pem|key|truststore|keystore'


⸻

10) Check DB connectivity clues from app config

If you find a JDBC URL, note it exactly.
Common patterns:

jdbc:mysql://host:3306/dbname
jdbc:postgresql://host:5432/dbname
jdbc:oracle:thin:@host:1521/service
jdbc:redshift://host:5439/dbname

Search specifically:

grep -RinE 'jdbc:mysql|jdbc:postgresql|jdbc:oracle|jdbc:redshift|jdbc:sqlserver' .


⸻

11) Check whether the app uses AWS services from code

grep -RinE 's3|sns|sqs|ses|secretsmanager|ssm|dynamodb|kinesis|lambda' .

This tells you whether you may need:
	•	IRSA/service account role
	•	AWS secret manager access
	•	S3 permissions

⸻

12) Collect a clean summary automatically

Run this script on the host from the repo root if possible:

cat > collect_app_runtime_info.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

echo "=== JAVA PROCESSES ==="
pgrep -a java || true

PID=$(pgrep -f 'java.*jar' | head -1 || true)
echo
echo "=== SELECTED PID ==="
echo "${PID:-NOT_FOUND}"

if [[ -n "${PID:-}" ]]; then
  echo
  echo "=== CMDLINE ==="
  tr '\0' ' ' < /proc/$PID/cmdline ; echo

  echo
  echo "=== ENV (FILTERED) ==="
  sudo strings /proc/$PID/environ | sort | egrep 'SPRING|DB_|DATABASE|JDBC|REDIS|MYSQL|POSTGRES|ORACLE|MONGO|KAFKA|RABBIT|AWS_|S3_|SECRET|TOKEN|USER|PASS|PROFILE|PORT|HOST|URL' || true

  echo
  echo "=== LISTEN PORTS FOR JAVA ==="
  sudo ss -ltnp | grep java || true
fi

echo
echo "=== CONFIG FILES IN CURRENT TREE ==="
find . -type f \( -name "application.properties" -o -name "application.yml" -o -name "application.yaml" -o -name "bootstrap.properties" -o -name "bootstrap.yml" \) 2>/dev/null || true

echo
echo "=== CONFIG KEYS SEARCH ==="
grep -RinE 'spring\.datasource|jdbc:|username|password|dbhost|dbHost|db_name|dbname|database|redshift|mysql|postgres|oracle|redis|mongo|kafka|rabbit|secret|token|api[-_]?key|aws\.|server\.port|SPRING_PROFILES_ACTIVE|spring\.profiles' . 2>/dev/null || true
EOF

chmod +x collect_app_runtime_info.sh
./collect_app_runtime_info.sh | tee app_runtime_report.txt


⸻

13) What to capture and send back

From all this, collect:

1. Java process command
2. Active Spring profile
3. App port
4. JDBC URL or DB host/port/dbname
5. DB username source
6. DB password source
7. All non-secret env var names used by app
8. All secret names/keys used by app
9. Any AWS services used by app
10. Any files the app reads for config


⸻

14) Very important: what not to paste openly

Do not paste actual:
	•	passwords
	•	tokens
	•	API keys
	•	full secret values

Instead paste:
	•	key names
	•	variable names
	•	masked URLs if needed

Example:

SPRING_DATASOURCE_URL=jdbc:mysql://<host>:3306/<db>
SPRING_DATASOURCE_USERNAME=<set>
SPRING_DATASOURCE_PASSWORD=<set>

If you share the outputs or screenshots from:
	•	systemctl cat ...
	•	/proc/$PID/cmdline
	•	filtered env vars
	•	app config search

I’ll turn that into the exact list of:
	•	Kubernetes Secrets
	•	ConfigMap/env vars
	•	deployment changes
	•	service port settings
