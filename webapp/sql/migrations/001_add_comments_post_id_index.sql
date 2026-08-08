-- 調査の経緯と計測結果: docs/tuning/001-comments-post-id-index.md
-- created_at を第2カラムに含めるのは ORDER BY created_at DESC の filesort を消すため。
ALTER TABLE comments ADD INDEX idx_post_id_created_at (post_id, created_at);
