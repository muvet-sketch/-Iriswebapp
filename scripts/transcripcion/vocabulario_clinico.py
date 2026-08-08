# -*- coding: utf-8 -*-
"""
Vocabulario clinico compartido por los dos pasos del flujo de transcripcion.

Por que existe: la transcripcion automatica no reconoce nombres de farmacos ni
tecnicismos que no estan en su vocabulario ("meloxicam" -> "melo si can",
"Traumeel" -> "trau mil"). Este modulo concentra ese vocabulario en un solo
lugar y lo sirve en los dos formatos que el flujo necesita:

  - PROMPT_WHISPER: prompt inicial CORTO para vigilante.py. Whisper solo usa
    los ultimos ~224 tokens del initial_prompt (si es mas largo, descarta el
    PRINCIPIO), asi que aca no cabe todo: es una seleccion de lo mas frecuente,
    con lo mas dificil de reconocer al FINAL, que es la parte que sobrevive.
  - glosario_para_llm(): glosario COMPLETO para extraer_soip.py. Claude si
    puede recibir cientos de terminos, y los usa para reconocer y corregir
    palabras mal transcritas (nunca para inventar menciones, ver la regla 8
    del prompt de extraer_soip.py).

Fuentes:
  - FARMACOS_PLUMB: indice del "Manual Farmacologico Veterinario" (Plumb,
    edicion en espanol). Extraido por OCR y corregido a mano; si un nombre se
    ve raro, verificar contra el manual antes de "corregirlo" de nuevo.
  - FARMACOS_ADICIONALES: farmacos de uso comun en clinica de pequenos en
    Colombia que esa edicion no trae (antiparasitarios de isoxazolina,
    biologicos, etc.).
  - HOMEOPATICOS_HEEL: lineas Heel que la clinica usa con frecuencia.
  - DIAGNOSTICOS_Y_PATOGENOS / TERMINOS_CLINICOS: del informe "Analisis
    Exhaustivo de Diagnosticos Veterinarios" (enfermedades tropicales de
    Colombia y su nomenclatura).

Para agregar vocabulario nuevo (un producto que la clinica empiece a usar,
una marca comercial local), agregarlo a la lista que corresponda. Si ademas
se oye MUY seguido en los audios, sumarlo al final de PROMPT_WHISPER — sin
olvidar que ese prompt tiene presupuesto fijo (~224 tokens).
"""

# --------------------------------------------------------------------------
# Homeopaticos Heel (uso frecuente en los audios de esta clinica)
# --------------------------------------------------------------------------

HOMEOPATICOS_HEEL = [
    "Traumeel", "Zeel", "Engystol", "Lymphomyosot", "Neurexan", "Nervoheel",
    "Spascupreel", "Gastricumeel", "Gripp-Heel", "Vertigoheel", "Euphorbium",
    "Atopeel", "Discus compositum", "Entero-Balance", "Nuxeel",
    "Echinacea compositum", "Belladonna-Homaccord", "Mucosa compositum",
    "Flamosin", "Lachesis compositum", "Coenzyme compositum",
    "Ubichinon compositum", "Ovarium compositum", "Solidago compositum",
    "Renheel", "Apis-Homaccord", "Drosera-Homaccord", "Momordica compositum",
    "Leptandra compositum", "Medulla ossis suis", "Colocynthis-Homaccord",
    "Pulsatilla compositum", "Hepar compositum", "Hepeel", "Galium-Heel",
    "Glyoxal compositum", "Thyreoidea compositum", "Zeel T", "Traumeel S",
]

# --------------------------------------------------------------------------
# Farmacos del Plumb (indice de monografias, OCR corregido a mano)
# --------------------------------------------------------------------------

FARMACOS_PLUMB = [
    # Sistemicos A-C
    "Acemanano", "Acepromacina", "Acetaminofen", "Paracetamol", "Acetazolamida",
    "Aciclovir", "Acido aminocaproico", "Acido ascorbico", "Acido etacrinico",
    "Acido tolfenamico", "Acido valproico", "Acidos grasos omega", "Acitretina",
    "Aglepristona", "Albuterol", "Salbutamol", "Alendronato", "Alfentanilo",
    "Alopurinol", "Altrenogest", "Hidroxido de aluminio", "Amantadina",
    "Amikacina", "Aminofilina", "Teofilina", "Amiodarona", "Amitriptilina",
    "Cloruro de amonio", "Amoxicilina", "Amoxicilina con acido clavulanico",
    "Ampicilina", "Sulbactam", "Amprolio", "Anfotericina B", "Antiveneno",
    "Apomorfina", "Apramicina", "Aspirina", "Atenolol", "Atipamezol",
    "Atovacuona", "Atracurio", "Atropina", "Auranofina", "Azaperona",
    "Azitromicina", "Aztreonam", "Azul de metileno", "Baclofeno", "Benazepril",
    "Betametasona", "Betanecol", "Bicarbonato de sodio", "Bisacodilo",
    "Subsalicilato de bismuto", "Bleomicina", "Boldenona", "Bromocriptina",
    "Bromuro de potasio", "Bromuro de sodio", "Buprenorfina", "Buspirona",
    "Busulfano", "Butorfanol", "Sales de calcio", "Calcitonina", "Calcitriol",
    "Caolin con pectina", "Captopril", "Carbenicilina", "Carbimazol",
    "Carbon activado", "Carboplatino", "Carnitina", "Carprofeno", "Carvedilol",
    "Caspofungina", "Cefaclor", "Cefadroxilo", "Cefalexina", "Cefapirina",
    "Cefazolina", "Cefepima", "Cefixima", "Cefotaxima", "Cefotetan",
    "Cefoxitina", "Cefpodoxima", "Ceftazidima", "Ceftiofur", "Ceftriaxona",
    "Cefuroxima", "Cetirizina", "Cianocobalamina", "Vitamina B12",
    "Ciclofosfamida", "Ciclosporina", "Cimetidina", "Cinc", "Ciprofloxacina",
    "Cisaprida", "Cisplatino", "Citarabina", "Clemastina", "Clenbuterol",
    "Clindamicina", "Clofazimina", "Clonazepam", "Clonidina", "Clopidogrel",
    "Cloprostenol", "Cloracepato", "Clorambucilo", "Cloranfenicol",
    "Clordiacepoxido", "Clorfeniramina", "Clorotiacida", "Clorpromacina",
    "Clorpropamida", "Clorsulon", "Clortetraciclina", "Codeina", "Colchicina",
    "Corticotropina", "Cosintropina",
    # D-G
    "Dacarbacina", "Dactinomicina", "Dalteparina", "Danofloxacina", "Dapsona",
    "Darbepoyetina alfa", "Decoquinato", "Deferoxamina", "Deracoxib",
    "Deslorelina", "Desoxicorticosterona", "Detomidina", "Dexametasona",
    "Dexmedetomidina", "Dexpantenol", "Dexrazoxano", "Dextran 70", "Diazepam",
    "Diclazuril", "Diclofenaco", "Diclorfenamida", "Diclorvos", "Dicloxacilina",
    "Dietilcarbamacina", "Dietilestilbestrol", "Difenhidramina", "Difenoxilato",
    "Difloxacina", "Digoxina", "Diltiazem", "Dimenhidrinato",
    "Dimetil sulfoxido", "Diminaceno", "Dinoprost", "Dirlotapida",
    "Disopiramida", "Dobutamina", "Docusato", "Dolasetron", "Domperidona",
    "Doramectina", "Doxapram", "Doxepina", "Doxiciclina", "Doxorrubicina",
    "Edetato de calcio disodico", "Edrofonio", "Efedrina", "Enalapril",
    "Enoxaparina", "Enrofloxacina", "Epinefrina", "Adrenalina",
    "Eritropoyetina", "Eprinomectina", "Epsiprantel", "Ergocalciferol",
    "Ertapenem", "Esmolol", "Espectinomicina", "Espironolactona", "Estanozolol",
    "Cipionato de estradiol", "Estreptoquinasa", "Estreptozocina", "Etambutol",
    "Etanol", "Etidronato", "Etodolac", "Etomidato", "Famciclovir",
    "Famotidina", "Felbamato", "Fenbendazol", "Fenilbutazona", "Fenilefrina",
    "Fenitoina", "Fenobarbital", "Fenoxibenzamina", "Fentanilo", "Feromonas",
    "Filgrastim", "Finasterida", "Firocoxib", "Fisostigmina", "Fitonadiona",
    "Vitamina K", "Flavoxato", "Florfenicol", "Flucitosina", "Fluconazol",
    "Fludrocortisona", "Flumazenil", "Flumetasona", "Flunixina meglumina",
    "Fluorouracilo", "Fluoxetina", "Fluticasona", "Fluvoxamina", "Fomepizol",
    "Furazolidona", "Furosemida", "Gabapentina", "Gemcitabina", "Gemfibrozilo",
    "Gentamicina", "Gliburida", "Glicerina", "Glicopirrolato", "Glimepirida",
    "Glipizida", "Glucosamina con condroitina",
    "Glicosaminoglicanos polisulfatados", "Glutamina",
    "Gonadotropina corionica", "Granisetron", "Griseofulvina", "Guaifenesina",
    # H-M
    "Heparina", "Hetalmidon", "Hidroclorotiacida", "Hidrocodona",
    "Hidrocortisona", "Hidromorfona", "Hidroxicina", "Hidroxiurea",
    "Hierro dextrano", "Hiosciamina", "Ifosfamida", "Imidocarb",
    "Imipenem con cilastatina", "Imipramina", "Insulina", "Interferon alfa",
    "Ipecacuana", "Ipratropio", "Irbesartan", "Isoflupredona", "Isoflurano",
    "Isoproterenol", "Dinitrato de isosorbida", "Isotretinoina", "Isoxsuprina",
    "Itraconazol", "Ivermectina", "Ketamina", "Ketoconazol", "Ketoprofeno",
    "Ketorolaco", "Lactulosa", "Leflunomida", "Leucovorina", "Leuprolida",
    "Levamisol", "Levetiracetam", "Levotiroxina", "Lidocaina", "Lincomicina",
    "Liotironina", "Lisina", "Lisinopril", "Lomustina", "Loperamida",
    "Lorazepam", "Lufenuron", "Hidroxido de magnesio", "Manitol",
    "Marbofloxacina", "Maropitant", "Meclicina", "Medetomidina",
    "Medroxiprogesterona", "Megestrol", "Antimoniato de meglumina",
    "Melarsomina", "Melatonina", "Meloxicam", "Meperidina", "Mercaptopurina",
    "Meropenem", "Metadona", "Metazolamida", "Metenamina", "Metformina",
    "Metilfenidato", "Metilprednisolona", "Metiltestosterona", "Metimazol",
    "Metionina", "Metocarbamol", "Metoclopramida", "Metohexital", "Metoprolol",
    "Metotrexato", "Metoxiflurano", "Metronidazol", "Mexiletina", "Mibolerona",
    "Micofenolato", "Midazolam", "Milbemicina oxima", "Minociclina",
    "Mirtazapina", "Misoprostol", "Mitotano", "Mitoxantrona", "Morantel",
    "Morfina", "Moxidectina",
    # N-S
    "Nandrolona", "Naproxeno", "N-butilescopolamina", "Buscapina", "Neomicina",
    "Neostigmina", "Niacinamida", "Nistatina", "Nitazoxanida", "Nitenpiram",
    "Nitrofurantoina", "Nitroprusiato", "Nizatidina", "Novobiocina",
    "Octreotida", "Olsalacina", "Omeprazol", "Ondansetron", "Orbifloxacina",
    "Oseltamivir", "Oxacilina", "Oxfendazol", "Oxibendazol", "Oxibutinina",
    "Oximorfona", "Oxitetraciclina", "Oxitocina", "Pamidronato", "Pancrelipasa",
    "Pancuronio", "Paromomicina", "Paroxetina", "Penicilamina", "Penicilina G",
    "Penicilina V", "Pentazocina", "Pentobarbital", "Polisulfato de pentosano",
    "Pentoxifilina", "Pergolida", "Pimobendan",
    "Piperacilina con tazobactam", "Piperacina", "Pirantel", "Piridostigmina",
    "Piridoxina", "Vitamina B6", "Pirilamina", "Pirimetamina", "Pirlimicina",
    "Piroxicam", "Ponazuril", "Potasio", "Pralidoxima", "Praziquantel",
    "Prazosina", "Prednisolona", "Prednisona", "Primaquina", "Primidona",
    "Probenecid", "Procainamida", "Procarbacina", "Proclorperacina",
    "Propantelina", "Propofol", "Propranolol", "Psyllium", "Quinacrina",
    "Quinidina", "Ramipril", "Ranitidina", "Rifampicina", "Romifidina",
    "S-adenosilmetionina", "Selamectina", "Selegilina", "Sertralina",
    "Seudoefedrina", "Sevelamer", "Sildenafil", "Silimarina", "Cardo mariano",
    "Somatotropina", "Sotalol", "Succimero", "Sucralfato", "Sufentanilo",
    "Sulfaclorpiridacina", "Sulfadiacina con trimetoprim",
    "Sulfametoxazol con trimetoprim", "Trimetoprim sulfa", "Sulfadimetoxina",
    "Sulfasalacina", "Sulfato ferroso", "Taurina",
    # T-Z
    "Tepoxalina", "Terbinafina", "Terbutalina", "Testosterona", "Tetraciclina",
    "Tiabendazol", "Tiamina", "Ticarcilina", "Tiletamina con zolazepam",
    "Zoletil", "Tilmicosina", "Tiludronato", "Tinidazol", "Tioguanina",
    "Tiopental", "Tiopronina", "Tiosulfato de sodio", "Tirotropina",
    "Tobramicina", "Tocainida", "Tolazolina", "Topiramato", "Torsemida",
    "Tramadol", "Triamcinolona", "Trientina", "Trigliceridos de cadena media",
    "Trilostano", "Trimepracina con prednisolona", "Tripelenamina",
    "Tulatromicina", "Ursodiol", "Vancomicina", "Vasopresina", "Verapamilo",
    "Vinblastina", "Vincristina", "Vitamina E con selenio", "Voriconazol",
    "Warfarina", "Xilacina", "Yoduro de potasio", "Yohimbina", "Zafirlukast",
    "Zidovudina", "Zonisamida",
    # Oftalmicos y dermatologicos topicos
    "Proparacaina", "Pilocarpina", "Apraclonidina", "Brimonidina", "Betaxolol",
    "Carteolol", "Levobunolol", "Metipranolol", "Timolol", "Brinzolamida",
    "Dorzolamida", "Latanoprost", "Bimatoprost", "Travoprost", "Ciclopentolato",
    "Tropicamida", "Cromolin", "Lodoxamida", "Olopatadina", "Nepafenaco",
    "Loteprednol", "Nalbufina", "Gatifloxacina", "Levofloxacina",
    "Moxifloxacina", "Norfloxacina", "Ofloxacina", "Sulfacetamida",
    "Natamicina", "Miconazol", "Yodopovidona", "Valaciclovir", "Ganciclovir",
    "Cidofovir", "Idoxuridina", "Trifluridina", "Tacrolimus",
    "Acido hialuronico", "Lagrimas artificiales", "Mupirocina", "Nitrofurazona",
    "Bacitracina", "Polimixina B", "Peroxido de benzoilo", "Clorhexidina",
    "Triclosan", "Clotrimazol", "Enilconazol", "Sulfuro de selenio",
    "Acido salicilico", "Fitosfingosina", "Imiquimod", "Tretinoina",
    # Antiparasitarios topicos
    "Amitraz", "Crotamiton", "Fipronil", "Metopreno", "Imidacloprid",
    "Permetrina", "Metaflumizona", "Piriproxifeno", "Piretrinas", "Espinosad",
]

# Uso comun en clinica de pequenos en Colombia; no estan en esa edicion del Plumb.
FARMACOS_ADICIONALES = [
    "Afoxolaner", "NexGard", "Fluralaner", "Bravecto", "Sarolaner", "Simparica",
    "Lotilaner", "Credelio", "Oclacitinib", "Apoquel", "Lokivetmab",
    "Cytopoint", "Bedinvetmab", "Librela", "Frunevetmab", "Solensia",
    "Robenacoxib", "Onsior", "Cefovecina", "Convenia", "Grapiprant",
    "Mavacoxib", "Telmisartan", "Amlodipino", "Miltefosina", "Toltrazuril",
    "Emodepsida", "Febantel", "Drontal", "Azatioprina", "Dipirona",
    "Ampicilina con sulbactam", "Nitenpyram", "Moxidectina con imidacloprid",
    "Advocate", "Ranitidina", "Esomeprazol", "Sucralfato", "Vetalog",
]

FARMACOS = FARMACOS_PLUMB + FARMACOS_ADICIONALES

# --------------------------------------------------------------------------
# Diagnosticos, patogenos y terminos clinicos (informe de enfermedades
# tropicales en Colombia)
# --------------------------------------------------------------------------

DIAGNOSTICOS_Y_PATOGENOS = [
    # Enfermedades
    "Ehrlichiosis", "Anaplasmosis", "Babesiosis", "Hepatozoonosis",
    "Leishmaniosis", "Dirofilariosis", "Tripanosomiasis",
    "Enfermedad de Chagas", "Esporotricosis", "Histoplasmosis",
    "Criptococosis", "Hemoplasmosis", "Micoplasmosis", "Citauxzoonosis",
    "Leptospirosis", "Rickettsiosis", "Toxoplasmosis", "Parvovirosis",
    "Moquillo", "Distemper", "Traqueobronquitis infecciosa",
    "Tos de las perreras", "Hepatitis infecciosa canina", "Rabia",
    "Panleucopenia felina", "Rinotraqueitis felina", "Calicivirus",
    "Leucemia felina", "Inmunodeficiencia felina",
    "Peritonitis infecciosa felina", "Demodicosis", "Sarna sarcoptica",
    "Otoacariasis", "Miasis", "Giardiasis", "Coccidiosis", "Dipilidiasis",
    "Anemia hemolitica inmunomediada", "Trombocitopenia inmunomediada",
    "Complejo granuloma eosinofilico", "Dermatitis atopica",
    "Dermatitis alergica por pulgas", "Enfermedad renal cronica",
    "Insuficiencia renal aguda", "Pancreatitis", "Piometra",
    "Enfermedad valvular degenerativa", "Cardiomiopatia hipertrofica",
    "Cardiomiopatia dilatada", "Sindrome braquicefalico",
    "Colapso traqueal", "Displasia de cadera", "Enfermedad periodontal",
    "Gingivoestomatitis", "Lipidosis hepatica", "Triaditis felina",
    "Hipertiroidismo", "Hipotiroidismo", "Hiperadrenocorticismo",
    "Sindrome de Cushing", "Hipoadrenocorticismo", "Enfermedad de Addison",
    "Diabetes mellitus", "Sindrome de Horner", "Queratoconjuntivitis seca",
    "Uveitis", "Glaucoma", "TVT", "Tumor venereo transmisible", "Linfoma",
    "Mastocitoma", "Osteosarcoma", "Hemangiosarcoma",
    # Patogenos y vectores
    "Ehrlichia canis", "Anaplasma phagocytophilum", "Anaplasma platys",
    "Babesia canis", "Babesia vogeli", "Babesia gibsoni", "Hepatozoon canis",
    "Leishmania infantum", "Trypanosoma cruzi", "Trypanosoma evansi",
    "Mycoplasma haemofelis", "Mycoplasma haemocanis", "Cytauxzoon felis",
    "Sporothrix brasiliensis", "Sporothrix schenckii",
    "Histoplasma capsulatum", "Dirofilaria immitis",
    "Bordetella bronchiseptica", "Leptospira", "Toxocara canis",
    "Toxocara cati", "Toxascaris leonina", "Ancylostoma caninum",
    "Uncinaria stenocephala", "Trichuris vulpis", "Dipylidium caninum",
    "Giardia", "Isospora", "Rhipicephalus sanguineus",
    "Ctenocephalides felis", "Demodex canis", "Sarcoptes scabiei",
    "Otodectes cynotis", "Malassezia",
]

TERMINOS_CLINICOS = [
    "anamnesis", "pirexia", "letargo", "caquexia", "emaciacion", "anorexia",
    "hiporexia", "emesis", "hematemesis", "diarrea sanguinolenta", "melena",
    "hematoquecia", "tenesmo", "disquecia", "poliuria", "polidipsia",
    "polifagia", "disuria", "estranguria", "hematuria", "hemoglobinuria",
    "proteinuria", "azotemia", "linfadenopatia", "linfadenomegalia",
    "esplenomegalia", "hepatomegalia", "hepatoesplenomegalia", "ascitis",
    "efusion pleural", "epistaxis", "petequias", "equimosis",
    "trombocitopenia", "pancitopenia", "leucopenia", "leucocitosis",
    "neutrofilia", "anemia regenerativa", "anemia no regenerativa",
    "parasitemia", "mucosas palidas", "mucosas ictericas", "ictericia",
    "mucosas congestivas", "cianosis", "deshidratacion", "turgencia cutanea",
    "condicion corporal", "soplo cardiaco", "arritmia", "taquicardia",
    "bradicardia", "taquipnea", "disnea", "estertores", "sibilancias",
    "estridor", "tos productiva", "secrecion nasal", "secrecion ocular",
    "blefaroespasmo", "anisocoria", "miosis", "midriasis", "nistagmo",
    "estrabismo", "ataxia", "paresia", "paralisis", "convulsiones",
    "opistotonos", "prurito", "alopecia", "eritema", "hiperqueratosis",
    "onicogrifosis", "liquenificacion", "pustulas", "pioderma", "seborrea",
    "otitis externa", "otitis media", "cerumen", "claudicacion", "cojera",
    "crepitacion", "dolor a la palpacion abdominal", "distension abdominal",
    "hernia", "criptorquidia", "secrecion vulvar", "galactorrea",
    "gestacion", "eutanasia", "profilaxis dental", "ovariohisterectomia",
    "orquiectomia", "esterilizacion", "sedacion", "induccion", "intubacion",
    "fluidoterapia", "cristaloides", "hemograma", "quimica sanguinea",
    "creatinina", "BUN", "nitrogeno ureico", "ALT", "fosfatasa alcalina",
    "albumina", "globulinas", "urianalisis", "coproscopico", "frotis",
    "citologia", "biopsia", "raspado de piel", "tricograma",
    "prueba de fluoresceina", "test de Schirmer", "ecografia abdominal",
    "ecocardiografia", "radiografia", "snap test", "PCR", "serologia",
    "titulacion de anticuerpos",
]

# --------------------------------------------------------------------------
# Salidas
# --------------------------------------------------------------------------

def glosario_para_llm() -> str:
    """Glosario completo, en secciones, para anexar al prompt de extraer_soip.py."""
    return "\n".join([
        "FARMACOS Y PRODUCTOS VETERINARIOS:",
        ", ".join(FARMACOS) + ".",
        "",
        "HOMEOPATICOS (marca Heel):",
        ", ".join(HOMEOPATICOS_HEEL) + ".",
        "",
        "DIAGNOSTICOS, ENFERMEDADES Y PATOGENOS:",
        ", ".join(DIAGNOSTICOS_Y_PATOGENOS) + ".",
        "",
        "TERMINOS CLINICOS FRECUENTES:",
        ", ".join(TERMINOS_CLINICOS) + ".",
    ])


# Prompt inicial para Whisper. Presupuesto: ~224 tokens (verificado con el
# tokenizer real del modelo medium; si se pasa, Whisper descarta el PRINCIPIO),
# por eso lo mas dificil de reconocer (homeopaticos Heel, que no existen en el
# vocabulario del modelo) va al FINAL, que es la parte que sobrevive.
PROMPT_WHISPER = (
    "Consulta veterinaria, paciente canino o felino. Terminos: "
    "desparasitacion, hemograma, quimica sanguinea, creatinina, "
    "tiempo de llenado capilar, "
    "ehrlichiosis, leishmaniosis, babesiosis, parvovirosis, "
    "piometra, ivermectina, praziquantel, fenbendazol, afoxolaner, "
    "meloxicam, carprofeno, dexametasona, prednisolona, enrofloxacina, "
    "cefalexina, doxiciclina, maropitant, "
    "Traumeel, Zeel, Engystol, Lymphomyosot, Hepeel, Nuxeel, "
    "Echinacea compositum, Mucosa compositum, Coenzyme compositum, "
    "Ubichinon compositum, Belladonna Homaccord, Gastricumeel, "
    "Spascupreel, Neurexan."
)
