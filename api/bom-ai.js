export default async function handler(req,res){
  if(req.method!=="POST") return res.status(405).json({error:"POST_ONLY"});

  try{
    const {username,password,image}=req.body||{};
    if(!username||!password||!image) return res.status(400).json({error:"필수 정보가 없습니다."});
    if(typeof image!=="string" || !image.startsWith("data:image/")) return res.status(400).json({error:"이미지 형식이 아닙니다."});
    if(image.length>17_000_000) return res.status(413).json({error:"이미지가 너무 큽니다."});

    const supabaseUrl=process.env.SUPABASE_URL;
    const supabaseAnon=process.env.SUPABASE_ANON_KEY;
    const openaiKey=process.env.OPENAI_API_KEY;
    if(!supabaseUrl||!supabaseAnon||!openaiKey){
      return res.status(500).json({error:"Vercel 환경변수 설정이 필요합니다."});
    }

    // VVIP 계정인지 서버에서 다시 검증
    const auth=await fetch(`${supabaseUrl}/rest/v1/rpc/verify_vvip_login`,{
      method:"POST",
      headers:{
        "Content-Type":"application/json",
        "apikey":supabaseAnon,
        "Authorization":`Bearer ${supabaseAnon}`
      },
      body:JSON.stringify({p_username:username,p_password:password})
    });
    if(!auth.ok) return res.status(401).json({error:"VVIP 인증 실패"});
    const authData=await auth.json();
    if(!Array.isArray(authData)||!authData.length||authData[0]?.role!=="vvip"){
      return res.status(403).json({error:"VVIP 전용 기능입니다."});
    }

    const schema={
      type:"object",
      additionalProperties:false,
      properties:{
        document_title:{type:"string"},
        warning:{type:"string"},
        lines:{
          type:"array",
          items:{
            type:"object",
            additionalProperties:false,
            properties:{
              part_no:{type:"string"},
              item_name:{type:"string"},
              qty_per_unit:{type:["number","null"]},
              unit:{type:"string"},
              confidence:{type:"number"}
            },
            required:["part_no","item_name","qty_per_unit","unit","confidence"]
          }
        }
      },
      required:["document_title","warning","lines"]
    };

    const ai=await fetch("https://api.openai.com/v1/responses",{
      method:"POST",
      headers:{
        "Content-Type":"application/json",
        "Authorization":`Bearer ${openaiKey}`
      },
      body:JSON.stringify({
        model:process.env.OPENAI_BOM_MODEL||"gpt-5.6-luna",
        reasoning:{effort:"low"},
        input:[{
          role:"user",
          content:[
            {
              type:"input_text",
              text:"이 이미지는 제조 BOM 또는 자재 소요량 표입니다. 표에 실제로 보이는 품목 행만 추출하세요. 품번(part_no), 품명(item_name), 완제품 1대당 소요량(qty_per_unit), 단위(unit)를 읽으세요. 글자가 불명확하면 추측해서 채우지 말고 빈 문자열 또는 null을 사용하세요. confidence는 해당 행 판독 신뢰도를 0~1로 주세요. 합계/제목/페이지번호/재고수량은 BOM 소요량으로 오인하지 마세요. 반드시 JSON 스키마에 맞춰 반환하세요."
            },
            {type:"input_image",image_url:image,detail:"high"}
          ]
        }],
        text:{
          format:{
            type:"json_schema",
            name:"bom_extraction",
            strict:true,
            schema
          }
        },
        max_output_tokens:8000
      })
    });

    const aiData=await ai.json();
    if(!ai.ok){
      console.error(aiData);
      return res.status(502).json({error:aiData?.error?.message||"AI 분석 요청 실패"});
    }

    const out=aiData.output_text ||
      aiData.output?.flatMap(o=>o.content||[]).find(c=>c.type==="output_text")?.text;
    if(!out) return res.status(502).json({error:"AI 분석 결과가 비어 있습니다."});

    const parsed=JSON.parse(out);
    return res.status(200).json(parsed);
  }catch(e){
    console.error(e);
    return res.status(500).json({error:e?.message||"BOM AI 서버 오류"});
  }
}
