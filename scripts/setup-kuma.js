const { io } = require("socket.io-client");
const fs = require("fs");

const KUMA_URL = process.env.KUMA_URL || "http://uptime-kuma:3001";
const USERNAME = process.env.KUMA_USERNAME || "admin";
const PASSWORD = process.env.KUMA_PASSWORD || "AdminStrongPassword321!";

// 1. Чистый опрос доступности HTTP без гонок (через нативный fetch Node 20)
async function waitForHttpReady() {
    console.log(`Waiting for Uptime Kuma HTTP server at ${KUMA_URL}...`);
    for (let i = 1; i <= 30; i++) {
        try {
            const res = await fetch(KUMA_URL, { signal: AbortSignal.timeout(3000) });
            if (res.status < 500) {
                console.log(`HTTP server is up (status ${res.status}).`);
                return;
            }
        } catch (e) {
            // сервер еще поднимается
        }
        await new Promise((r) => setTimeout(r, 1500));
    }
    throw new Error("HTTP connection timed out.");
}

// 2. Попытка запроса needSetup с коротким таймаутом (защита от фоновых миграций БД)
function tryConnectAndCheckSetup() {
    return new Promise((resolve, reject) => {
        const socket = io(KUMA_URL, {
            transports: ["websocket"],
            reconnection: false,
            timeout: 3000
        });

        // Если Kuma занята миграцией и не отвечает на needSetup за 3 секунды — разрываем
        const timer = setTimeout(() => {
            socket.disconnect();
            reject(new Error("Database is busy migrating (needSetup timeout)."));
        }, 3000);

        socket.on("connect", () => {
            socket.emit("needSetup", (needed) => {
                clearTimeout(timer);
                resolve({ socket, needed });
            });
        });

        socket.on("connect_error", (err) => {
            clearTimeout(timer);
            socket.disconnect();
            reject(err);
        });
    });
}

// 3. Основной сценарий с умным ожиданием готовности БД
async function main() {
    await waitForHttpReady();

    let session = null;
    console.log("Checking database readiness via WebSocket...");

    // Опрашиваем needSetup, пока БД не освободится
    for (let attempt = 1; attempt <= 20; attempt++) {
        try {
            session = await tryConnectAndCheckSetup();
            console.log("Database migrations finished! Uptime Kuma backend is 100% READY.");
            break;
        } catch (err) {
            console.log(`Waiting for MariaDB migrations to complete... (attempt ${attempt}/20)`);
            await new Promise((r) => setTimeout(r, 2000));
        }
    }

    if (!session) {
        console.error("Failed to establish operational session with Uptime Kuma.");
        process.exit(1);
    }

    const { socket, needed } = session;

    // Регистрация или Вход
    if (needed) {
        console.log("First-time setup: creating administrator...");
        socket.emit("setup", USERNAME, PASSWORD, (res) => {
            if (!res || !res.ok) {
                console.error("Setup failed:", res ? res.msg : "unknown error");
                socket.disconnect();
                process.exit(1);
            }
            console.log("Admin created successfully. Authenticating session...");
            loginAndGenerateKey(socket);
        });
    } else {
        console.log("Instance already initialized. Authenticating session...");
        loginAndGenerateKey(socket);
    }
}

function loginAndGenerateKey(socket) {
    socket.emit("login", { username: USERNAME, password: PASSWORD }, (loginRes) => {
        if (!loginRes || !loginRes.ok) {
            console.error("Login failed:", loginRes ? loginRes.msg : "no response");
            socket.disconnect();
            process.exit(1);
        }
        console.log("Authenticated. Generating API Key...");
        
        socket.emit("addAPIKey", { name: "prometheus-scraper", expires: null }, (res) => {
            let apiKey = null;
            if (typeof res === "string") {
                apiKey = res;
            } else if (res && res.key) {
                apiKey = res.key;
            } else if (res && res.data && res.data.key) {
                apiKey = res.data.key;
            }

            if (apiKey) {
                console.log(`\n===========================================`);
                console.log(`>>> API Key created: ${apiKey} <<<`);
                console.log(`===========================================\n`);

                // Безопасное сохранение в смонтированную папку secrets
                try {
                    const tokenDir = "/output/secrets";
                    if (!fs.existsSync(tokenDir)) {
                        fs.mkdirSync(tokenDir, { recursive: true });
                    }
                    fs.writeFileSync(`${tokenDir}/kuma.token`, apiKey.trim(), { mode: 0o644 });
                    console.log("Token successfully written to secrets/kuma.token (mode 600)");
                } catch (err) {
                    console.warn("Could not save token file:", err.message);
                }
            } else {
                console.log("API Key step completed (key might already exist).");
            }

            socket.disconnect();
            process.exit(0);
        });
    });
}

main().catch((err) => {
    console.error("Fatal error:", err.message);
    process.exit(1);
});