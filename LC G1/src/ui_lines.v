// ============================================================================
// ui_lines.v - 静态界面文字表（自动生成，勿手改）
//   (scr,row,col) -> 字形码 + 行属性（0 普通 / 2 标题 / 3 暗）
//   动态内容（乐器名、音名、滑轨条/数值、光标）在 ui_text.v 里叠加
// ============================================================================
module ui_lines (
    input  wire [2:0] scr,
    input  wire [4:0] row,
    input  wire [4:0] col,
    output reg  [6:0] code,
    output reg  [1:0] attr
);
    always @(*) begin
        code = 7'd0;
        attr = 2'd0;
        case (scr)
        3'd0: begin
            case (row)
            5'd1: begin attr = 2'd2;
                case (col)
                5'd5: code = 7'd65;
                5'd6: code = 7'd66;
                5'd7: code = 7'd71;
                5'd8: code = 7'd13;
                5'd9: code = 7'd1;
                5'd10: code = 7'd2;
                5'd11: code = 7'd67;
                5'd12: code = 7'd68;
                default: code = 7'd0;
                endcase
            end
            5'd3: begin attr = 2'd0;
                case (col)
                5'd7: code = 7'd1;
                5'd8: code = 7'd2;
                5'd9: code = 7'd3;
                5'd10: code = 7'd4;
                default: code = 7'd0;
                endcase
            end
            5'd5: begin attr = 2'd0;
                case (col)
                5'd7: code = 7'd5;
                5'd8: code = 7'd6;
                5'd9: code = 7'd3;
                5'd10: code = 7'd4;
                default: code = 7'd0;
                endcase
            end
            5'd7: begin attr = 2'd0;
                case (col)
                5'd7: code = 7'd100;
                5'd8: code = 7'd93;
                5'd9: code = 7'd92;
                5'd10: code = 7'd7;
                5'd11: code = 7'd8;
                5'd12: code = 7'd3;
                5'd13: code = 7'd4;
                default: code = 7'd0;
                endcase
            end
            5'd9: begin attr = 2'd0;
                case (col)
                default: code = 7'd0;
                endcase
            end
            default: ;
            endcase
        end
        3'd1: begin
            case (row)
            5'd1: begin attr = 2'd2;
                case (col)
                5'd9: code = 7'd1;
                5'd10: code = 7'd2;
                5'd11: code = 7'd3;
                5'd12: code = 7'd4;
                default: code = 7'd0;
                endcase
            end
            5'd4: begin attr = 2'd0;
                case (col)
                5'd6: code = 7'd11;
                5'd7: code = 7'd12;
                5'd8: code = 7'd13;
                5'd9: code = 7'd3;
                5'd10: code = 7'd4;
                default: code = 7'd0;
                endcase
            end
            5'd6: begin attr = 2'd0;
                case (col)
                5'd6: code = 7'd71;
                5'd7: code = 7'd13;
                5'd8: code = 7'd3;
                5'd9: code = 7'd4;
                default: code = 7'd0;
                endcase
            end
            default: ;
            endcase
        end
        3'd2: begin
            case (row)
            5'd1: begin attr = 2'd2;
                case (col)
                5'd8: code = 7'd1;
                5'd9: code = 7'd2;
                5'd10: code = 7'd3;
                5'd11: code = 7'd4;
                default: code = 7'd0;
                endcase
            end
            default: ;
            endcase
        end
        3'd3: begin
            case (row)
            5'd1: begin attr = 2'd2;
                case (col)
                5'd9: code = 7'd5;
                5'd10: code = 7'd6;
                5'd11: code = 7'd3;
                5'd12: code = 7'd4;
                default: code = 7'd0;
                endcase
            end
            5'd4: begin attr = 2'd0;
                case (col)
                5'd5: code = 7'd11;
                5'd6: code = 7'd12;
                5'd7: code = 7'd13;
                5'd8: code = 7'd5;
                5'd9: code = 7'd6;
                default: code = 7'd0;
                endcase
            end
            5'd6: begin attr = 2'd0;
                case (col)
                5'd5: code = 7'd71;
                5'd6: code = 7'd13;
                5'd7: code = 7'd5;
                5'd8: code = 7'd6;
                default: code = 7'd0;
                endcase
            end
            default: ;
            endcase
        end
        3'd4: begin
            case (row)
            5'd0: begin attr = 2'd0;
                case (col)
                5'd1: code = 7'd5;
                5'd2: code = 7'd6;
                5'd3: code = 7'd118;
                default: code = 7'd0;
                endcase
            end
            5'd1: begin attr = 2'd0;
                case (col)
                5'd1: code = 7'd14;
                5'd2: code = 7'd15;
                5'd3: code = 7'd118;
                default: code = 7'd0;
                endcase
            end
            5'd3: begin attr = 2'd0;
                case (col)
                5'd1: code = 7'd14;
                5'd2: code = 7'd5;
                5'd21: code = 7'd115;
                5'd23: code = 7'd27;
                5'd24: code = 7'd28;
                5'd25: code = 7'd84;
                5'd26: code = 7'd79;
                5'd27: code = 7'd115;
                default: code = 7'd0;
                endcase
            end
            5'd5: begin attr = 2'd0;
                case (col)
                5'd1: code = 7'd16;
                5'd2: code = 7'd17;
                5'd21: code = 7'd115;
                5'd23: code = 7'd27;
                5'd24: code = 7'd28;
                5'd25: code = 7'd84;
                5'd26: code = 7'd79;
                5'd27: code = 7'd115;
                default: code = 7'd0;
                endcase
            end
            5'd7: begin attr = 2'd0;
                case (col)
                5'd1: code = 7'd20;      // 起音 A
                5'd2: code = 7'd14;
                5'd3: code = 7'd89;
                5'd21: code = 7'd115;
                5'd23: code = 7'd27;
                5'd24: code = 7'd28;
                5'd25: code = 7'd84;
                5'd26: code = 7'd79;
                5'd27: code = 7'd115;
                default: code = 7'd0;
                endcase
            end
            5'd9: begin attr = 2'd0;
                case (col)
                5'd1: code = 7'd21;      // 衰减 D
                5'd2: code = 7'd22;
                5'd3: code = 7'd92;
                5'd21: code = 7'd115;
                5'd23: code = 7'd27;
                5'd24: code = 7'd28;
                5'd25: code = 7'd84;
                5'd26: code = 7'd79;
                5'd27: code = 7'd115;
                default: code = 7'd0;
                endcase
            end
            5'd11: begin attr = 2'd0;
                case (col)
                5'd1: code = 7'd23;      // 释放 R
                5'd2: code = 7'd24;
                5'd3: code = 7'd106;
                5'd21: code = 7'd115;
                5'd23: code = 7'd27;
                5'd24: code = 7'd28;
                5'd25: code = 7'd84;
                5'd26: code = 7'd79;
                5'd27: code = 7'd115;
                default: code = 7'd0;
                endcase
            end
            5'd13: begin attr = 2'd0;
                case (col)
                5'd1: code = 7'd18;      // 泛音比（最后一行）
                5'd2: code = 7'd14;
                5'd3: code = 7'd19;
                5'd21: code = 7'd115;
                5'd23: code = 7'd27;
                5'd24: code = 7'd28;
                5'd25: code = 7'd84;
                5'd26: code = 7'd79;
                5'd27: code = 7'd115;
                default: code = 7'd0;
                endcase
            end
            default: ;
            endcase
        end
        3'd5: begin
            case (row)
            5'd1: begin attr = 2'd2;
                case (col)
                5'd9: code = 7'd100;
                5'd10: code = 7'd93;
                5'd11: code = 7'd92;
                5'd12: code = 7'd7;
                5'd13: code = 7'd8;
                5'd14: code = 7'd3;
                5'd15: code = 7'd4;
                default: code = 7'd0;
                endcase
            end
            5'd3: begin attr = 2'd2;
                case (col)
                5'd10: code = 7'd29;
                5'd11: code = 7'd30;
                default: code = 7'd0;
                endcase
            end
            5'd5: begin attr = 2'd0;
                case (col)
                5'd6: code = 7'd32;
                5'd7: code = 7'd33;
                default: code = 7'd0;
                endcase
            end
            5'd7: begin attr = 2'd0;
                case (col)
                5'd6: code = 7'd36;
                5'd7: code = 7'd37;
                5'd8: code = 7'd29;
                5'd9: code = 7'd30;
                5'd10: code = 7'd80;
                default: code = 7'd0;
                endcase
            end
            5'd9: begin attr = 2'd0;
                case (col)
                5'd6: code = 7'd36;
                5'd7: code = 7'd37;
                5'd8: code = 7'd29;
                5'd9: code = 7'd30;
                5'd10: code = 7'd81;
                default: code = 7'd0;
                endcase
            end
            5'd11: begin attr = 2'd0;
                case (col)
                5'd6: code = 7'd36;
                5'd7: code = 7'd37;
                5'd8: code = 7'd29;
                5'd9: code = 7'd30;
                5'd10: code = 7'd82;
                default: code = 7'd0;
                endcase
            end
            default: ;
            endcase
        end
        3'd6: begin
            case (row)
            5'd1: begin attr = 2'd2;
                case (col)
                5'd9: code = 7'd7;
                5'd10: code = 7'd8;
                5'd11: code = 7'd3;
                5'd12: code = 7'd4;
                default: code = 7'd0;
                endcase
            end
            5'd4: begin attr = 2'd0;
                case (col)
                5'd4: code = 7'd29;
                5'd5: code = 7'd30;
                5'd6: code = 7'd118;
                default: code = 7'd0;
                endcase
            end
            default: ;
            endcase
        end
        3'd7: begin
            case (row)
            default: ;
            endcase
        end
        default: ;
        endcase
    end
endmodule
