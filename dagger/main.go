package main

import (
	"context"
	"fmt"

	"dagger/monitoring-stand/internal/dagger"
)

type MonitoringStand struct{}

// dockerContainer подготавливает окружение: гарантирует правильные файлы .env и .my.cnf
// как внутри Dagger, так и на самом хосте (устраняет ложные директории Docker)
func (m *MonitoringStand) dockerContainer(sock *dagger.Socket, src *dagger.Directory, hostPath string) *dagger.Container {
	return dag.Container().
		From("docker:29.9.2-cli-alpine3.24").
		WithUnixSocket("/var/run/docker.sock", sock).
		WithMountedDirectory("/workspace", src).
		WithWorkdir("/workspace").
		// 1. Гарантируем файлы внутри Dagger workspace:
		WithExec([]string{
			"sh", "-c",
			"test -f /workspace/.env || cp /workspace/.env.example /workspace/.env; test -f /workspace/.my.cnf || cp /workspace/.my.cnf.example /workspace/.my.cnf",
		}).
		// 2. Гарантируем файлы на самом хосте (удаляем ошибочные папки .my.cnf/, если Docker их создал):
		WithExec([]string{
			"docker", "run", "--rm",
			"-v", fmt.Sprintf("%s:/host", hostPath),
			"alpine:3.24.3",
			"sh", "-c",
			"test -d /host/.my.cnf && rm -rf /host/.my.cnf; test -f /host/.my.cnf || cp /host/.my.cnf.example /host/.my.cnf; test -f /host/.env || cp /host/.env.example /host/.env",
		})
}

// deployLayer — хелпер для запуска слоев Docker Compose
func (m *MonitoringStand) deployLayer(
	ctx context.Context,
	sock *dagger.Socket,
	src *dagger.Directory,
	hostPath string,
	composeFileName string,
) (string, error) {
	return m.dockerContainer(sock, src, hostPath).
		WithExec([]string{
			"docker", "compose",
			"--project-directory", hostPath,
			"-f", fmt.Sprintf("/workspace/%s", composeFileName),
			"--env-file", "/workspace/.env",
			"up", "-d", "--wait",
		}).
		Stdout(ctx)
}

// runInNetwork — хелпер для выполнения скриптов внутри сети platform_net
func (m *MonitoringStand) runInNetwork(
	ctx context.Context,
	sock *dagger.Socket,
	src *dagger.Directory,
	hostPath string,
	image string,
	galera bool,
	cmd []string,
) (string, error) {
	dockerCmd := []string{
		"docker", "run", "--rm",
		"--network", "platform_net",
		"--env-file", "/workspace/.env",
		"-e", fmt.Sprintf("GALERA_MODE=%t", galera),
		"-v", fmt.Sprintf("%s/scripts:/scripts:ro", hostPath),
		"-v", fmt.Sprintf("%s/dashboards:/payloads:ro", hostPath),
		"-v", fmt.Sprintf("%s:/output:rw", hostPath),
		"-w", "/scripts",
		image,
	}
	dockerCmd = append(dockerCmd, cmd...)

	return m.dockerContainer(sock, src, hostPath).
		WithExec(dockerCmd).
		Stdout(ctx)
}

// DeployApp поднимает Слой 1 (MariaDB + Uptime Kuma)
// +cache="never"
func (m *MonitoringStand) DeployApp(
	ctx context.Context,
	dockerSock *dagger.Socket,
	hostPath string,
	// +defaultPath="."
	source *dagger.Directory,
) (string, error) {
	return m.deployLayer(ctx, dockerSock, source, hostPath, "docker-compose.app.yaml")
}

// DeployGalera поднимает отказоустойчивый кластер MariaDB (3 ноды Galera) + HAProxy + Uptime Kuma
// +cache="never"
func (m *MonitoringStand) DeployGalera(
	ctx context.Context,
	dockerSock *dagger.Socket,
	hostPath string,
	// +defaultPath="."
	source *dagger.Directory,
) (string, error) {
	return m.deployLayer(ctx, dockerSock, source, hostPath, "docker-compose.galera.yaml")
}

// DeployMonitoring поднимает Слой 2 (Prometheus, Grafana, Exporters)
// +cache="never"
func (m *MonitoringStand) DeployMonitoring(
	ctx context.Context,
	dockerSock *dagger.Socket,
	hostPath string,
	// +defaultPath="."
	source *dagger.Directory,
	// +optional
	// +default=false
	galera bool,
) (string, error) {
	profile := "single"
	promConfigFile := "./prometheus.yaml"

	if galera {
		profile = "galera"
		promConfigFile = "./prometheus.galera.yaml"
	}

	return m.dockerContainer(dockerSock, source, hostPath).
		WithEnvVariable("PROMETHEUS_CONFIG", promConfigFile).
		WithExec([]string{
			"docker", "compose",
			"--project-directory", hostPath,
			"-f", "/workspace/docker-compose.monitoring.yaml",
			"--env-file", "/workspace/.env",
			"--profile", profile,
			"up", "-d", "--wait",
		}).
		Stdout(ctx)
}

// SetupKuma настраивает первого пользователя Kuma через WebSocket
// +cache="never"
func (m *MonitoringStand) SetupKuma(
	ctx context.Context,
	dockerSock *dagger.Socket,
	hostPath string,
	// +defaultPath="."
	source *dagger.Directory,
) (string, error) {
	return m.runInNetwork(ctx, dockerSock, source, hostPath, "node:20-alpine", false, []string{
		"sh", "-c", "cd /tmp && npm install --no-package-lock --silent socket.io-client@4.7.5 > /dev/null 2>&1 && NODE_PATH=/tmp/node_modules node -e 'require(\"/scripts/setup-kuma.js\")'",
	})
}

// ConfigureGrafana настраивает Data Sources и Dashboards в Grafana через API
// +cache="never"
func (m *MonitoringStand) ConfigureGrafana(
	ctx context.Context,
	dockerSock *dagger.Socket,
	hostPath string,
	// +defaultPath="."
	source *dagger.Directory,
	// +optional
	// +default=false
	galera bool,
) (string, error) {
	return m.runInNetwork(ctx, dockerSock, source, hostPath, "curlimages/curl:8.23.0", galera, []string{
		"/bin/sh", "/scripts/configure-grafana.sh",
	})
}

// ChaosTest запускает тестирование отказоустойчивости MariaDB
// +cache="never"
func (m *MonitoringStand) ChaosTest(
	ctx context.Context,
	dockerSock *dagger.Socket,
	hostPath string,
	// +defaultPath="."
	source *dagger.Directory,
) (string, error) {
	return m.dockerContainer(dockerSock, source, hostPath).
		WithExec([]string{
			"/bin/sh", "/workspace/scripts/chaos-test.sh",
		}).
		Stdout(ctx)
}

// ValidateHealth проводит проверку здоровья всех компонентов контура
// +cache="never"
func (m *MonitoringStand) ValidateHealth(
	ctx context.Context,
	dockerSock *dagger.Socket,
	hostPath string,
	// +defaultPath="."
	source *dagger.Directory,
	// +optional
	// +default=false
	galera bool,
) (string, error) {
	return m.runInNetwork(ctx, dockerSock, source, hostPath, "curlimages/curl:8.23.0", galera, []string{
		"/bin/sh", "/scripts/validate-health.sh",
	})
}

// DeployAll выполняет полный E2E запуск стенда и валидацию здоровья
// +cache="never"
func (m *MonitoringStand) DeployAll(
	ctx context.Context,
	dockerSock *dagger.Socket,
	hostPath string,
	// +defaultPath="."
	source *dagger.Directory,
	// +optional
	// +default=false
	galera bool,
) (string, error) {
	// 1. Слой приложения
	if galera {
		if _, err := m.DeployGalera(ctx, dockerSock, hostPath, source); err != nil {
			return "", fmt.Errorf("deploy-galera failed: %w", err)
		}
	} else {
		if _, err := m.DeployApp(ctx, dockerSock, hostPath, source); err != nil {
			return "", fmt.Errorf("deploy-app failed: %w", err)
		}
	}

	// 2. Инициализация Kuma
	if _, err := m.SetupKuma(ctx, dockerSock, hostPath, source); err != nil {
		return "", fmt.Errorf("setup-kuma failed: %w", err)
	}

	// 3. Запуск контура мониторинга с нужным профилем (single или galera)
	if _, err := m.DeployMonitoring(ctx, dockerSock, hostPath, source, galera); err != nil {
		return "", fmt.Errorf("deploy-monitoring failed: %w", err)
	}

	// 4. Конфигурация Grafana через API
	if _, err := m.ConfigureGrafana(ctx, dockerSock, hostPath, source, galera); err != nil {
		return "", fmt.Errorf("configure-grafana failed: %w", err)
	}

	// 5. Комплексный Healthcheck всех систем (с учетом режима)
	return m.ValidateHealth(ctx, dockerSock, hostPath, source, galera)
}

// Destroy полностью останавливает стенд и удаляет volumes и сети
// +cache="never"
func (m *MonitoringStand) Destroy(
	ctx context.Context,
	dockerSock *dagger.Socket,
	hostPath string,
	// +defaultPath="."
	source *dagger.Directory,
) (string, error) {
	return m.dockerContainer(dockerSock, source, hostPath).
		WithExec([]string{"docker", "compose", "--project-directory", hostPath, "-f", "/workspace/docker-compose.monitoring.yaml", "down", "-v", "--remove-orphans"}).
		WithExec([]string{"docker", "compose", "--project-directory", hostPath, "-f", "/workspace/docker-compose.galera.yaml", "down", "-v", "--remove-orphans"}).
		WithExec([]string{"docker", "compose", "--project-directory", hostPath, "-f", "/workspace/docker-compose.app.yaml", "down", "-v", "--remove-orphans"}).
		Stdout(ctx)
}