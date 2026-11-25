#ifndef CZSIGN_BRIDGE_H
#define CZSIGN_BRIDGE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    const char* input_ipa_path;
    const char* output_ipa_path;
    const char* p12_path;
    const char* p12_password;
    const char* mobileprovision_path;
    const char* custom_bundle_id;
    const char* custom_display_name;
    const char* custom_bundle_version;
    const char* temp_directory_path;
    int adhoc_sign;
    int remove_extensions;
    int enable_documents;
    int zip_level;
} czsign_options_t;

/**
 * Ký gói .ipa (hoặc thư mục .app) bằng nhân ZSign C++ & OpenSSL 3.6.
 * Trả về 0 nếu thành công và chữ ký Mach-O đầu ra đã được xác minh hợp lệ;
 * trả về mã âm nếu thất bại và ghi thông báo lỗi UTF-8 vào error_buf.
 */
int czsign_sign_ipa(
    const czsign_options_t* options,
    char* error_buf,
    uint32_t error_buf_size
);

/**
 * Kiểm tra cấu trúc chữ ký LC_CODE_SIGNATURE của tệp thực thi Mach-O sau khi ký.
 * Trả về 0 nếu có CSMAGIC_EMBEDDED_SIGNATURE & CSMAGIC_CODEDIRECTORY hợp lệ.
 */
int czsign_verify_macho_signature(
    const char* macho_path,
    int require_cms_blob,
    char* error_buf,
    uint32_t error_buf_size
);

/**
 * Kiểm tra chứng chỉ (.p12 / .mobileprovision / Mach-O) kèm truy vấn OCSP trực tiếp tới Apple
 * sử dụng kho WWDR Intermediate G1-G8 nhúng sẵn trong ZSign.
 * Trả về: 0 = Hợp lệ (Good), 1 = Đã thu hồi (Revoked), 2 = Hết hạn (Expired), -2 = Chưa ký, -1 = Lỗi.
 */
int czsign_check_certificate(
    const char* file_path,
    const char* password
);

#ifdef __cplusplus
}
#endif

#endif /* CZSIGN_BRIDGE_H */
