// Temporary diagnostic: compare platform verifier vs bundled roots without any proxy.
async fn hit(name: &str, c: &reqwest::Client) {
    for u in ["https://api.bangumi.lat/v0/subjects/541285", "https://lain.bangumi.lat/r/400/pic/cover/l/b3/26/541285_CYBZc.jpg", "https://api.bgm.tv/v0/subjects/541285"] {
        let t = std::time::Instant::now();
        let r = c.get(u).header("User-Agent", "Kurako/1.0").send().await;
        println!("{name} {u} -> {:?} {:?}", r.map(|r| r.status()).map_err(|e| format!("{e:?}").chars().take(300).collect::<String>()), t.elapsed());
    }
}
#[tokio::main]
async fn main() {
    let platform = reqwest::Client::builder().no_proxy().timeout(std::time::Duration::from_secs(30)).build().unwrap();
    hit("platform", &platform).await;
}
