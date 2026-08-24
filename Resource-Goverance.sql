-- CPU/Parrallelism Goverance 
OPTION (MAXDOP 3) 

-- Concurency/Lock Goverance
WITH (ROWLOCK) 


-- I/O and Optimizer Control force use a specific index
WITH (INDEX (table_name))

