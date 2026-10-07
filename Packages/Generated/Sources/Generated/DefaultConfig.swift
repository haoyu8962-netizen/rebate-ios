// 生成物，禁止手改；来源 contract.lock
// 快照：contracts/openapi.yaml GET /v1/config 200 响应示例的 data（03 §4.3 包内 default_config.json）。
// 去掉了地址类字段（h5_base_url、share_domains、kf）并清空 link_patterns.rules：示例里是
// example.test 占位地址，不能进包。
// TODO(N-21): 发布构建时改为从生产配置当时的值生成（03 §4.3：features.search_status 等取生产值）。

/// 包内默认配置（`ConfigStore` 没有当前配置与 LKG 时的最后一层）。
public enum DefaultConfig {
    public static let json: Swift.String = "{\"agent\":{\"enabled\":true,\"examples\":[\"帮我找 500 元以内的降噪耳机\"],\"filing_text\":\"\",\"guest_daily_quota\":3,\"require_phone\":false,\"whitelist_only\":true},\"app_update\":{\"recheck_interval_sec\":1800},\"auth_tips\":{},\"bridge_origins\":{},\"claim\":{\"window_days\":30},\"clipboard\":{},\"compliance\":{},\"dict_version\":\"2026100201\",\"display\":{},\"external_hosts\":[],\"external_page\":{\"nav_host_sample_bp\":100},\"features\":{\"flags\":{\"agent.entry.visible\":true,\"clipboard.enabled.taobao\":true,\"earnings.dashboard.visible\":false,\"external_page.product_intercept\":true,\"external_page.union_host_block\":true,\"ui.grayscale\":false},\"platform_status\":{\"jd\":\"on\",\"pdd\":\"not_launched\",\"taobao\":\"on\"},\"search_status\":{\"jd\":\"off\",\"taobao\":\"on\"}},\"h5_release\":{\"version\":\"1.4.2\"},\"help_links\":{\"price_compare\":{\"params\":{\"article_id\":\"example-article-one\"},\"route\":\"Help\"}},\"invite\":{\"backfill_hours\":168,\"before_buy_tip\":true,\"bind_phone_guide\":true,\"required\":false},\"jump_tip\":{},\"legal\":{\"agreement\":{\"version\":2},\"privacy\":{\"min_version\":3,\"version\":3}},\"link_patterns\":{\"rules\":[],\"version\":\"2026100401\"},\"texts\":{\"withdraw.sla_text\":\"工作日 24 小时内处理\"}}"
}
